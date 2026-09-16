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

    def test_the_two_event_wakes_are_placed_and_gated_on_the_pumps_own_schedule(self):
        """GS-RUNTIME-001 step 4's last two wakes on this isle: an inbound request and newly committed forward work."""
        n = NODE.read_text(encoding="utf-8")
        self.assertIn("ackPump?.isScheduled(fromPeer) == true", n,
                      "BOTH wakes must be gated on THE PUMP'S OWN SCHEDULE: an unready relation is not served, and "
                      "nothing is guessed")
        # **THREE, NOT TWO -- AND THE MEASUREMENT CORRECTED MY OWN ARM: the READINESS wake (round 233's collector)
        # counteth here as well, beside the inbound request and the newly committed forward work.** A court that
        # asserteth a number it did not count is a court that will redden on the NEXT honest change.
        self.assertEqual(3, n.count("ackEventWakes++"),
                         "THREE event wakes stand on this isle: the readiness, the inbound request, and the newly "
                         "committed forward work")
        self.assertIn("ble.applicationLinkReady().collect", n, "the readiness wake (round 233's collector)")
        ack = n[n.index("is DispatchVerdict.Ack ->"):]
        ack = ack[:ack.index("return verdict.accepted")]
        self.assertIn("verdict.accepted && ackPump?.isScheduled(fromPeer) == true", ack,
                      "the FORWARD-WORK wake belongeth in the Ack case, on an ACCEPTED candidate")
        road = n[n.index("// GS-RUNTIME-001 step 4's INBOUND WAKE"):]
        self.assertIn("scope.launch { drainAckWorkOnce(fromPeer) }", road,
                      "and the INBOUND wake belongeth on the generic durable road")

    def test_the_farewell_unschedulleth_the_exact_relation(self):
        """GS-RUNTIME-001 step 3 on this isle: a relation that went away must STOP being eligible -- measured
        absent before this (`onLinkGone` was called NOWHERE in the production tree)."""
        n = NODE.read_text(encoding="utf-8")
        self.assertIn("ackPump?.onLinkGone(event.peerId)", n,
                      "the Farewell must unschedule THAT EXACT relation, or the worker offers to a departed peer")
        # **AND IT MUST STAND OUTSIDE THE `peerLock` BLOCK** -- a second lock taken inside the first is a nesting
        # nobody asked for. (My first draft put it INSIDE, which the compiler accepted and a reviewer should not.)
        handler = n[n.index("internal fun handlePeerEvent"):]
        handler = handler[:handler.index("\n    }")]
        lock_at = handler.index("synchronized(peerLock)")
        unlock_at = handler.index("publishStatus()")
        call_at = handler.index("ackPump?.onLinkGone(event.peerId)")
        self.assertGreater(call_at, unlock_at,
                           "the unscheduling must stand AFTER the lock's block, not inside it")
        self.assertGreater(call_at, lock_at, "sanity: the call is in the handler at all")

    def test_the_generation_recheck_is_not_needed_here_and_the_reason_is_recorded(self):
        """**A MEASURED DIFFERENCE FROM THE SWIFT TWIN, RECORDED SO IT IS NOT MISTAKEN FOR AN OMISSION:**
        this isle's pump is keyed by THE AUTHENTICATED NODE ID (and its transport send taketh a node id), so
        there is NO HANDLE THAT A REPLACEMENT RELATION COULD REUSE -- which is why the Swift isle needed a
        generation recheck and this one doth not. What this isle needed was the FAREWELL, above."""
        p = PUMP.read_text(encoding="utf-8")
        self.assertIn("fun onLinkReady(peer: ByteArray, now: Long = clock())", p,
                      "the schedule is keyed by the node id, which IS the authenticated identity on this isle")
        n = NODE.read_text(encoding="utf-8")
        self.assertIn("ble.send(nodeId, copy.encodedFrame)", n,
                      "and the transport send taketh that same node id -- no handle, no reuse, no recheck")

    def test_the_adapter_asketh_for_a_measured_teardown(self):
        """GS-RUNTIME-001 step 2 on this isle: the hard-coded `1` is dead, and the FILE'S OWN PRECEDENT is the law."""
        a = (MESH / "transport/LifecycleTransportAdapter.kt").read_text(encoding="utf-8")
        self.assertIn("(transport as? DisconnectingTransport)?.disconnectAll() ?: 0", a,
                      "the adapter must BELIEVE a reporting transport and otherwise CLAIM NOTHING -- the audit's "
                      "class of defect (a literal wearing the clothes of a measurement) is thereby closed here too")
        self.assertNotIn("return 1\n    }\n\n    /**\n     * ANDROID-05 (step 3)", a,
                          "and the literal must be GONE")
        self.assertIn("interface DisconnectingTransport : Transport {",
                      (MESH / "transport/Transport.kt").read_text(encoding="utf-8"),
                      "with the capability declared where the transport contract liveth")

    def test_the_node_driveth_the_radio_through_one_authority_and_closeth_before_its_guard(self):
        """IOS-06's twin on this isle, and the SWIFT WITNESS'S OWN LESSON applied here BEFORE a witness had to find
        it: the close road sat after an early return that ALWAYS fires in this shipping tree."""
        n = (REPO / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt").read_text(encoding="utf-8")
        self.assertIn("internal val lifecycle: UnifiedRuntimeLifecycle by lazy {", n,
                      "the node must OWN ONE authority over its own transport (nothing constructed it before)")
        self.assertIn("seam = LifecycleTransportAdapter(ble)", n,
                      "and it must be built OVER THE ADAPTER over THIS node's transport")
        self.assertIn("lifecycle.start()", n, "the open road must travel through the authority")
        stop = n[n.index("fun stop() {"):]
        stop = stop[:stop.index("\n    }")]
        close_at = stop.index("lifecycle.stop()")
        guard_at = stop.index("if (!isStarted) return")
        self.assertLess(close_at, guard_at,
                        "**THE CLOSE MUST PRECEDE THE GUARD**: the Swift census arm found (round 244) that the "
                        "counter stood at ZERO -- the radio was never closed through the owner, ever, because "
                        "`isStarted` is false by construction in this tree")
        self.assertIn("adaptersClosedThroughTheOwner += 1", n,
                      "and a census must stand, so a witness can MEASURE which road was taken")
        self.assertIn("// IOS-06's twin", n)

    def test_the_signer_refuseth_the_seed_road_by_construction(self):
        signer = (MESH / "delivery/IdentityAckSigner.kt").read_text(encoding="utf-8")
        self.assertIn("override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray? = null",
                      signer,
                      "GS-RUNTIME-001 step 2: the PRODUCTION signer must refuse the harness seed road")
        self.assertIn("identity.identityPriv", signer,
                      "and sign with the pinned identity's own material, which never leaveth the module")


class IOS06LifecycleRoutingTest(unittest.TestCase):
    """IOS-06 step 1's second half, on the SWIFT isle -- **A SOURCE-LEVEL ARM, AND IT SAITH SO**: the node's
    transport path is `by lazy`/private over a real `BleTransport`, so a unit court cannot observe WHICH road the
    node took. What can be judged today is that the routing EXISTS and that the direct road is the fallback only."""

    IOS = REPO / "ios/Godstone/Sources/GodstoneMesh"

    def test_w00_the_authority_and_the_transport_still_stand(self):
        node = (self.IOS / "MeshNode.swift").read_text(encoding="utf-8")
        self.assertIn("lazy var ble = BleTransport()", node)
        auth = (self.IOS / "UnifiedRuntimeLifecycle.swift").read_text(encoding="utf-8")
        self.assertIn("public func start()", auth)
        self.assertIn("public func stop()", auth)

    def test_the_node_openeth_and_closeth_the_radio_through_the_owner(self):
        node = (self.IOS / "MeshNode.swift").read_text(encoding="utf-8")
        self.assertIn("internal var lifecycleOwner: UnifiedRuntimeLifecycle?", node,
                      "the node must HOLD the owner the runtime giveth it")
        for road, which in (("lifecycleOwner.start()", "open"), ("lifecycleOwner.stop()", "close")):
            self.assertIn(road, node, "IOS-06: the node must drive the radio through the authority on " + which)
        # THE DIRECT ROAD SURVIVETH ONLY AS A FALLBACK -- that is what maketh the change additive for every rig.
        # (A REGEX, NOT A LITERAL NEWLINE: my first draft put real line breaks inside the pattern string, because
        # the heredoc that wrote this file had ALREADY interpreted its escapes -- THE SAME DOUBLE-INTERPRETATION
        # THAT ONCE TRUNCATED A SOURCE FILE IN THIS SESSION, met here in a test instead.)
        self.assertRegex(node, r"\} else \{\s+ble\.start\(\)")
        self.assertRegex(node, r"\} else \{\s+ble\.stop\(\)")
        runtime = (self.IOS / "MeshRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("meshNode.lifecycleOwner = lifecycle", runtime,
                      "and the runtime must HAND the authority to its node, or the routing never happeneth")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
