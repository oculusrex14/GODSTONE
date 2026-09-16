"""CRYPTO-001: the crypto authority is addressed by RELATION, not by platform handle.

WHAT THIS COURT IS, HONESTLY: these are SOURCE-LEVEL arms. They read the tree's text
and assert the shape of the authority's surface. They do NOT run a session, and they
are NOT evidence that a stale operation is refused at runtime -- that evidence is the
Swift behavioural arms in the canonical subsystem suite
(`ios/Godstone/Tests/GodstoneMeshTests/SessionManagerTests.swift`, the CRYPTO-001
section) and the T08 arms which were rewritten in the same repair. This file exists
because two of the finding's demands are properties of the WHOLE CALLER GRAPH --
"remove peer-handle-only overloads from production call paths" and "capture the key
when the transport relation is admitted" -- and a source-level arm is the only
instrument which can see every call path at once.

The arms fail loudly on the species of defect this programme keeps meeting: a name
assumed instead of read (an arm asserting a line rather than a law is avoided here --
each arm asserts the LAW's shape, not its formatting).
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
IOS_MESH = ROOT / "ios/Godstone/Sources/GodstoneMesh"
ANDROID_CRYPTO = ROOT / "android/mesh/src/main/java/io/godstone/mesh/crypto"
ANDROID_TRANSPORT = ROOT / "android/mesh/src/main/java/io/godstone/mesh/transport"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    """Remove //-comments and /* */ blocks so a comment cannot answer for code."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


class Crypto001RelationKeyAuthority(unittest.TestCase):
    """The iOS half: the registry, the seam and every production call path."""

    def setUp(self):
        self.sm = strip_comments(read(IOS_MESH / "SessionManager.swift"))
        self.slot = strip_comments(read(IOS_MESH / "SessionSlot.swift"))
        self.transport = strip_comments(read(IOS_MESH / "BleTransport.swift"))
        self.node = strip_comments(read(IOS_MESH / "MeshNode.swift"))
        self.seam = strip_comments(read(IOS_MESH / "BleHandshakeAuthority.swift"))
        self.connection = strip_comments(read(IOS_MESH / "BleConnection.swift"))

    # ---------------------------------------------------------------- the identity
    def test_the_registry_is_keyed_by_the_relation_place_and_not_the_handle(self):
        self.assertIn("private var controllers: [RelationHandle: SessionSlot]", self.sm,
                      "the registry must be keyed by (direction, handle), not by UUID")

    def test_the_lookup_refuses_an_incarnation_that_no_longer_standeth(self):
        # The law: a slot standeth IFF the WHOLE admission equalleth. An arm that
        # asserted a particular spelling would punish every honest edit; this asserts
        # the comparison is present and is against the whole admission.
        self.assertRegex(self.sm, r"slot\.admission\s*==\s*admission",
                         "the lookup must compare the WHOLE admission, not the handle")

    def test_the_teardown_is_typed_and_can_refuse_a_replaced_relation(self):
        self.assertIn("public enum RelationRetirement", self.slot)
        self.assertIn("case stale", self.slot)
        self.assertRegex(self.sm, r"func drop\(_ admission: RelationAdmission\) -> RelationRetirement",
                         "drop must take an admission and answer with the typed retirement")
        self.assertIn("return .stale", self.sm,
                      "the absent/superseded incarnation must answer .stale")

    def test_the_crypto_registry_mints_no_generation_of_its_own(self):
        self.assertNotIn("rememberedGenerations", self.sm,
                         "the T08 generation history is reclaimed: the orchestration owner mints the generation")
        self.assertNotIn("SlotLease", self.sm,
                         "an independent crypto lease is the very thing the finding refused")
        self.assertNotIn("SlotLease", self.slot)

    def test_the_slot_reads_its_generation_from_the_admission(self):
        self.assertIn("internal let admission: RelationAdmission", self.slot)
        self.assertRegex(self.slot, r"internal var generation: UInt64 \{ admission\.relation\.generation \}",
                         "the slot's generation must be READ from the admission")

    # ---------------------------------------------------------------- the caller graph
    def test_production_never_addresses_the_authority_with_a_bare_handle(self):
        # The pre-T08 vocabulary exists (internal, for the host courts) but no
        # production line may speak it. The patterns below are the handle-shaped calls.
        handle_calls = [
            r"sessions\??\.drop\((?!Self\.admissionOf|BleTransport\.admissionOf|admission)",
            r"sessions\??\.seal\((?!admission|Self\.admissionOf)",
            r"sessions\??\.open(?:WithResult)?\((?!admission|Self\.admissionOf)",
            r"sessions\??\.isReady\((?!admission)",
            r"sessions\??\.authenticatedNodeIdOf\((?!admission)",
            r"sessions\??\.authenticatedIdentityPubOf\((?!admission)",
            r"sessions\??\.initiatorStart\((?!admission|replacement)",
            r"sessions\??\.initiatorProcessHs2\((?!admission)",
            r"sessions\??\.responderProcessHs1\((?!admission)",
            r"sessions\??\.responderProcessHs3\((?!admission)",
            r"registry\??\.openWithResult\((?!\$0|admission)",
            r"registry\.seal\((?!admission)",
        ]
        for pattern in handle_calls:
            found = re.findall(pattern, self.transport + "\n" + self.node)
            self.assertEqual(found, [],
                             f"production speaks the handle-only vocabulary: /{pattern}/ -> {found}")

    def test_the_handshake_seam_speaks_the_admission(self):
        for name in ("startOutboundHandshake", "continueOutboundHandshake",
                     "acceptInboundHandshake", "completeInboundHandshake"):
            self.assertRegex(self.seam, rf"func {name}\(relation: RelationAdmission",
                             f"{name} must take the relation's admission")

    def test_every_production_handshake_call_presents_an_admission(self):
        for call in ("startOutboundHandshake", "continueOutboundHandshake",
                     "acceptInboundHandshake", "completeInboundHandshake"):
            self.assertRegex(self.transport, rf"{call}\(relation: admission",
                             f"{call} must be given an admission in production")

    def test_the_connection_carrieth_the_admission_it_was_admitted_as(self):
        self.assertIn("internal var relationAdmission: RelationAdmission?", self.connection)

    def test_the_admission_is_stamped_at_every_admission_point(self):
        # One outbound admission (discovery) and two inbound admissions
        # (accept-write, accept-subscription). Each must stamp the standing connection.
        stamps = re.findall(r"relationAdmission\s*=\s*\n?\s*RelationAdmission\(relation: key", self.transport)
        self.assertGreaterEqual(len(stamps), 3,
                                "the admission must be stamped at every admission point")

    def test_the_mesh_node_speaks_the_handle_scoped_departure(self):
        # A node learns of a PEER's departure; it must not guess an admission.
        self.assertIn("retireIncarnations(ofPeerId: peerId)", self.node)
        self.assertNotRegex(self.node, r"sessions\.drop\(",
                            "the node must not tear the crypto registry down by handle")

    def test_a_connection_without_an_admission_is_not_given_to_the_authority(self):
        # The seal site must refuse when the connection carrieth no admission: an
        # absence of admission is an absence of relation, never a licence to guess.
        self.assertRegex(self.transport, r"guard let admission = connection\.relationAdmission else \{ return nil \}")



class Crypto001RelationKeyAuthorityAndroid(unittest.TestCase):
    """The ANDROID half, as far as it is landed. THE HONEST SCOPE OF THIS CLASS: the crypto LAYER is
    mirrored, and the TRANSPORT still speaks the pre-T08 host vocabulary -- so the arm which refuseth
    the handle-only vocabulary in PRODUCTION SOURCES is SKIPPED here, visibly and unclaimed, until the
    transport presenteth the relation's own admission (the next step of this finding). A skipped arm is
    a law this file may not yet assert; it is not a law which holdeth.
    """

    def setUp(self):
        self.sm = strip_comments(read(ANDROID_CRYPTO / "SessionManager.kt"))
        self.slot = strip_comments(read(ANDROID_CRYPTO / "SessionSlot.kt"))

    def test_the_android_key_carrieth_the_whole_relation(self):
        self.assertIn("enum class RelationDirection", self.slot)
        self.assertRegex(self.slot, r"data class RelationKey\(\s*val direction: RelationDirection,",
                         "the key must carry the DIRECTION")
        for field in ("val handle: String", "val generation: Long", "val transportEpoch: Long"):
            self.assertIn(field, self.slot, f"the key must carry {field}")

    def test_the_android_registry_is_keyed_by_the_relation_place(self):
        self.assertIn("private val controllers = HashMap<RelationPlace, SessionSlot>()", self.sm)
        self.assertRegex(self.sm, r"standing\.admission != admission",
                         "the lookup must compare the WHOLE admission, not the handle")

    def test_the_android_teardown_is_typed_and_can_refuse_a_replaced_relation(self):
        self.assertIn("enum class RelationRetirement { RETIRED, STALE }", self.slot)
        self.assertRegex(self.sm, r"fun drop\(admission: RelationKey\): RelationRetirement")
        self.assertIn("return RelationRetirement.STALE", self.sm)
        self.assertRegex(self.sm, r"fun retireIncarnations\(ofHandle: String\): Int")

    def test_the_android_crypto_registry_mints_no_generation_of_its_own(self):
        self.assertNotIn("rememberedGenerations", self.sm)
        self.assertNotIn("SlotLease", self.sm)
        self.assertNotIn("SlotLease", self.slot)
        self.assertRegex(self.slot, r"val generation: Long get\(\) = admission\.generation",
                         "the slot's generation must be READ from the admission")

    @unittest.skip("CRYPTO-001 (Android): the TRANSPORT still presents the pre-T08 host vocabulary; "
                   "this arm turneth green when every production crypto call presenteth the relation's "
                   "own admission (see the ledger's pending_proof for this finding)")
    def test_android_production_never_addresses_the_authority_with_a_bare_handle(self):
        transport = strip_comments(read(ANDROID_TRANSPORT / "BleTransport.kt"))
        for pattern in (r"sessions\??\.destroyFor\(peer", r"sessions\??\.authenticatedNodeIdOf\(peer",
                        r"registry\??\.openWithResult\(peer", r"registry\.isReady\(conn\.peerId\)"):
            self.assertEqual(re.findall(pattern, transport), [],
                             f"production speaks the handle-only vocabulary: /{pattern}/")

if __name__ == "__main__":
    unittest.main()
