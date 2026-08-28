#!/usr/bin/env python3
"""Structural and regression controls for Persistent Duplex BLE Link Substrate & Role Election (ADR-002, Phase C8.4D1-R2).

Verifies the presence, boundaries, and structural invariants of:
- BL01: Android BleRole enum and BleRoleElection pure unsigned-byte lexicographic comparison
- BL02: iOS BleRole enum and BleRoleElection pure unsigned-byte lexicographic comparison
- BL03: Android BleRoleElection equal hints fail closed (BleRoleElectionResult.Tie)
- BL04: iOS BleRoleElection equal hints fail closed (BleRoleElectionResult.tie)
- BL05: Android BleDiscoveryCodec 13-byte payload encode/decode (0x02 version, 4-byte hint, 6-byte digest, queue depth)
- BL06: iOS BleDiscoveryCodec 13-byte payload encode/decode (0x02 version, 4-byte hint, 6-byte digest, queue depth)
- BL07: Android BleConnection persistent duplex connection abstraction with connection-local BleRecord seam
- BL08: iOS BleConnection persistent duplex connection abstraction with connection-local BleRecord seam
- BL09: Android GattClientConnection persistent central connection with serialized mutex, notification subscription, MTU negotiation
- BL10: Android BleGattServer duplex peripheral server with notification capability (notifyCharacteristicChanged)
- BL11: iOS BleTransport responder notification path with updateValue backpressure queue
- BL12: Android BleTransport role coordinator integration and hint retention
- BL13: iOS BleTransport role coordinator integration and hint retention
- BL14: Android BleTransport connection teardown resets connection-local record reassembler
- BL15: iOS BleTransport connection teardown resets connection-local record reassembler
- BL16: Android resource bounds: MAX_DISCOVERED_PEERS = 64, MAX_ACTIVE_CONNECTIONS = 7
- BL17: iOS resource bounds: maxDiscoveredPeers = 64, maxActiveConnections = 7
- BL18: Android BleTransport startup order: GATT server starts before advertising
- BL19: iOS BleTransport privacy: service UUID only, no local name broadcast
- BL20: Android BleLinkSubstrateTest test inventory
- BL21: iOS BleLinkSubstrateTests test inventory
- BL22: No SessionManager handshake APIs called by production BLE transport
- BL23: Hard boundaries: LINK_LAYER_READY = false, linkLayerReady = false, LIGHT Archive-only
- BL24: ADR-002 and ADR-003 truthful representation of Phase C8.4D1-A1 and C8.4D1-R2 status
- BL25: Android persistent client connection wiring in BleTransport (instantiation, connect, storage)
- BL26: iOS central connection guarded by role coordinator
- BL27: Android startup fail-closed gating on gattServer.start() result
- BL28: Android server CCCD subscription tracking and enforcement in sendNotification
- BL29: Android server-side MTU callback wired to BleConnection
- BL30: iOS outbound write and update queues are strictly hard-bounded
- BL31: Generated LINK_INFO UUID parity across Android and iOS FrameV2
- BL32: No literal LINK_INFO UUID string hardcoded in platform transport code
- BL33: LinkInfo is not a BleRecord type code in BleRecordConstants
- BL34: BleConnectionState defines full lifecycle states (ROLE_BOUND, PROVISIONAL_CONNECTING, etc.)
- BL35: BleLinkInfoV1 and BleLinkInfoCodec 13-byte layout defined in Kotlin and Swift
- BL36: BleRoleBindingCoordinator defined on Android and iOS
- BL37: BleLinkInfo reference implementation and golden vectors authority
- BL38: Android BleGattServer onServiceAdded readiness callback enforcement
- BL39: Android BleGattServer LINK_INFO characteristic READ/WRITE support
- BL40: iOS BleTransport LINK_INFO characteristic READ/WRITE support
- BL41: Android GattClient ordered LinkInfo exchange & CCCD descriptor status verification
- BL42: Android BleConnection provisional state machine without mandatory pre-bind nodeHint/role & bindRole
- BL43: iOS BleConnection provisional state machine without mandatory pre-bind nodeHint/role & bindRole
- BL44: Application DATA strictly gated before READY state on Android and iOS
- BL45: Separate outbound Central and inbound Peripheral connection namespaces on iOS
- BL46: Android BleTransport snapshot authority derived from real state without synthetic fallback
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Paths
ANDROID_ROLE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRoleElection.kt"
ANDROID_COORD_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRoleBindingCoordinator.kt"
ANDROID_CONN_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleConnection.kt"
ANDROID_CLIENT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "GattClient.kt"
ANDROID_SERVER_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "GattServer.kt"
ANDROID_TRANSPORT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleTransport.kt"
ANDROID_TEST_SUBSTRATE_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleLinkSubstrateTest.kt"
ANDROID_MESH_NODE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "MeshNode.kt"
ANDROID_WIREV2_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "wire" / "v2" / "WireV2.kt"
ANDROID_RECORD_CODEC_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRecord.kt"

IOS_ROLE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRoleElection.swift"
IOS_COORD_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRoleBindingCoordinator.swift"
IOS_CONN_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleConnection.swift"
IOS_TRANSPORT_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleTransport.swift"
IOS_TEST_SUBSTRATE_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "BleLinkSubstrateTests.swift"
IOS_MESH_NODE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshNode.swift"
IOS_APP_CONTAINER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "App" / "AppContainer.swift"
IOS_WIREV2_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "WireV2.swift"
IOS_RECORD_CODEC_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRecord.swift"

WIRE_LINK_INFO_REF_PATH = ROOT / "wire" / "ble_link_info_reference.py"
WIRE_LINK_INFO_VEC_PATH = ROOT / "wire" / "ble_link_info_vectors.json"

ADR002_PATH = ROOT / "docs" / "adr" / "ADR-002-ble-record-layer.md"
ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"


def strip_comments(text: str) -> str:
    """Remove single-line and multi-line comments."""
    text = re.sub(r'//.*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def check_controls(
    android_role_path: Path = ANDROID_ROLE_PATH,
    android_coord_path: Path = ANDROID_COORD_PATH,
    android_conn_path: Path = ANDROID_CONN_PATH,
    android_client_path: Path = ANDROID_CLIENT_PATH,
    android_server_path: Path = ANDROID_SERVER_PATH,
    android_transport_path: Path = ANDROID_TRANSPORT_PATH,
    android_test_substrate_path: Path = ANDROID_TEST_SUBSTRATE_PATH,
    android_mesh_node_path: Path = ANDROID_MESH_NODE_PATH,
    android_wirev2_path: Path = ANDROID_WIREV2_PATH,
    android_record_codec_path: Path = ANDROID_RECORD_CODEC_PATH,
    ios_role_path: Path = IOS_ROLE_PATH,
    ios_coord_path: Path = IOS_COORD_PATH,
    ios_conn_path: Path = IOS_CONN_PATH,
    ios_transport_path: Path = IOS_TRANSPORT_PATH,
    ios_test_substrate_path: Path = IOS_TEST_SUBSTRATE_PATH,
    ios_mesh_node_path: Path = IOS_MESH_NODE_PATH,
    ios_app_container_path: Path = IOS_APP_CONTAINER_PATH,
    ios_wirev2_path: Path = IOS_WIREV2_PATH,
    ios_record_codec_path: Path = IOS_RECORD_CODEC_PATH,
    wire_link_info_ref_path: Path = WIRE_LINK_INFO_REF_PATH,
    wire_link_info_vec_path: Path = WIRE_LINK_INFO_VEC_PATH,
    adr002_path: Path = ADR002_PATH,
    adr003_path: Path = ADR003_PATH,
) -> list[str]:
    errors: list[str] = []

    # ------------------------------------------------------------------------
    # BL01: Android BleRole & BleRoleElection
    # ------------------------------------------------------------------------
    if not android_role_path.exists():
        errors.append(f"BL01: Android role election file missing at {android_role_path}")
    else:
        c = strip_comments(android_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\benum\s+class\s+BleRole\b', c) or "INITIATOR" not in c or "RESPONDER" not in c:
            errors.append("BL01: Android BleRole enum class missing INITIATOR/RESPONDER")
        if not re.search(r'\bobject\s+BleRoleElection\b', c):
            errors.append("BL01: Android BleRoleElection object missing")
        if "localHint[i].toInt() and 0xFF" not in c:
            errors.append("BL01: Android unsigned byte comparison missing in BleRoleElection")

    # ------------------------------------------------------------------------
    # BL02: iOS BleRole & BleRoleElection
    # ------------------------------------------------------------------------
    if not ios_role_path.exists():
        errors.append(f"BL02: iOS role election file missing at {ios_role_path}")
    else:
        c = strip_comments(ios_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\benum\s+BleRole\b', c) or "case initiator" not in c or "case responder" not in c:
            errors.append("BL02: iOS BleRole enum missing initiator/responder")
        if not re.search(r'\benum\s+BleRoleElection\b', c):
            errors.append("BL02: iOS BleRoleElection enum missing")
        if "l < r" not in c or "l > r" not in c:
            errors.append("BL02: iOS lexicographical comparison missing in BleRoleElection")

    # ------------------------------------------------------------------------
    # BL03: Android equal hints fail closed
    # ------------------------------------------------------------------------
    if android_role_path.exists():
        c = strip_comments(android_role_path.read_text(encoding="utf-8"))
        if "data object Tie" not in c or "BleRoleElectionResult.Tie" not in c:
            errors.append("BL03: Android equal hints must return BleRoleElectionResult.Tie")

    # ------------------------------------------------------------------------
    # BL04: iOS equal hints fail closed
    # ------------------------------------------------------------------------
    if ios_role_path.exists():
        c = strip_comments(ios_role_path.read_text(encoding="utf-8"))
        if "case tie" not in c or "return .tie" not in c:
            errors.append("BL04: iOS equal hints must return .tie")

    # ------------------------------------------------------------------------
    # BL05: Android BleDiscoveryCodec 13-byte payload
    # ------------------------------------------------------------------------
    if android_role_path.exists():
        c = strip_comments(android_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\bobject\s+BleDiscoveryCodec\b', c) or not re.search(r'object\s+BleDiscoveryConstants\s*\{[^}]*DISCOVERY_PAYLOAD_BYTES\s*=\s*13', c, re.DOTALL):
            errors.append("BL05: Android BleDiscoveryCodec 13-byte payload codec missing")

    # ------------------------------------------------------------------------
    # BL06: iOS BleDiscoveryCodec 13-byte payload
    # ------------------------------------------------------------------------
    if ios_role_path.exists():
        c = strip_comments(ios_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\benum\s+BleDiscoveryCodec\b', c) or not re.search(r'enum\s+BleDiscoveryConstants\s*\{[^}]*discoveryPayloadBytes\s*=\s*13', c, re.DOTALL):
            errors.append("BL06: iOS BleDiscoveryCodec 13-byte payload codec missing")

    # ------------------------------------------------------------------------
    # BL07: Android BleConnection persistent abstraction
    # ------------------------------------------------------------------------
    if not android_conn_path.exists():
        errors.append(f"BL07: Android BleConnection missing at {android_conn_path}")
    else:
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleConnection\s*\(', c):
            errors.append("BL07: Android BleConnection class missing")
        if "reassembler.reset()" not in c:
            errors.append("BL07: Android BleConnection reset missing reassembler.reset()")
        if "BleRecordFragmenter.fragment" not in c or "BleRecordCodec.decodeFragment" not in c:
            errors.append("BL07: Android BleConnection record seam missing")

    # ------------------------------------------------------------------------
    # BL08: iOS BleConnection persistent abstraction
    # ------------------------------------------------------------------------
    if not ios_conn_path.exists():
        errors.append(f"BL08: iOS BleConnection missing at {ios_conn_path}")
    else:
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleConnection\b', c):
            errors.append("BL08: iOS BleConnection class missing")
        if "reassembler.reset()" not in c:
            errors.append("BL08: iOS BleConnection reset missing reassembler.reset()")
        if "BleRecordFragmenter.fragment" not in c or "BleRecordCodec.decodeFragment" not in c:
            errors.append("BL08: iOS BleConnection record seam missing")

    # ------------------------------------------------------------------------
    # BL09: Android GattClientConnection persistent central connection
    # ------------------------------------------------------------------------
    if not android_client_path.exists():
        errors.append(f"BL09: Android GattClient file missing at {android_client_path}")
    else:
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+GattClientConnection\b', c):
            errors.append("BL09: Android GattClientConnection persistent class missing")
        if "gattMutex" not in c:
            errors.append("BL09: Android GattClientConnection serialized mutex missing")
        if "ENABLE_NOTIFICATION_VALUE" not in c:
            errors.append("BL09: Android notification subscription missing")

    # ------------------------------------------------------------------------
    # BL10: Android BleGattServer duplex peripheral server
    # ------------------------------------------------------------------------
    if not android_server_path.exists():
        errors.append(f"BL10: Android GattServer file missing at {android_server_path}")
    else:
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleGattServer\b', c):
            errors.append("BL10: Android BleGattServer class missing")
        if "notifyCharacteristicChanged" not in c:
            errors.append("BL10: Android BleGattServer notification support missing")

    # ------------------------------------------------------------------------
    # BL11: iOS BleTransport responder notification path
    # ------------------------------------------------------------------------
    if not ios_transport_path.exists():
        errors.append(f"BL11: iOS BleTransport missing at {ios_transport_path}")
    else:
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "peripheral.updateValue(" not in c or "pm.updateValue(" not in c:
            errors.append("BL11: iOS updateValue with onSubscribedCentrals missing")
        if "peripheralManagerIsReady" not in c:
            errors.append("BL11: iOS peripheralManagerIsReady backpressure handling missing")

    # ------------------------------------------------------------------------
    # BL12: Android BleTransport role coordinator integration
    # ------------------------------------------------------------------------
    if not android_transport_path.exists():
        errors.append(f"BL12: Android BleTransport missing at {android_transport_path}")
    else:
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if not re.search(r'\bval\s+roleCoordinator\s*=\s*BleRoleBindingCoordinator\b', c):
            errors.append("BL12: Android BleTransport missing role coordinator integration")

    # ------------------------------------------------------------------------
    # BL13: iOS BleTransport role coordinator integration
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if not re.search(r'\bvar\s+roleCoordinator:\s*BleRoleBindingCoordinator\b', c):
            errors.append("BL13: iOS BleTransport missing role coordinator integration")

    # ------------------------------------------------------------------------
    # BL14: Android BleTransport connection teardown
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "conn.markDisconnected()" not in c:
            errors.append("BL14: Android BleTransport missing conn.markDisconnected() teardown")

    # ------------------------------------------------------------------------
    # BL15: iOS BleTransport connection teardown
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "outboundCentralConnections.removeAll()" not in c:
            errors.append("BL15: iOS BleTransport missing conn.markDisconnected() teardown")

    # ------------------------------------------------------------------------
    # BL16: Android resource bounds
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "MAX_DISCOVERED_PEERS = 64" not in c or "MAX_ACTIVE_CONNECTIONS = 7" not in c:
            errors.append("BL16: Android resource bounds MAX_DISCOVERED_PEERS / MAX_ACTIVE_CONNECTIONS missing")

    # ------------------------------------------------------------------------
    # BL17: iOS resource bounds
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "maxDiscoveredPeers = 64" not in c or "maxActiveConnections = 7" not in c:
            errors.append("BL17: iOS resource bounds maxDiscoveredPeers / maxActiveConnections missing")

    # ------------------------------------------------------------------------
    # BL18: Android startup ordering
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        start_fn_idx = c.find("override fun start()")
        if start_fn_idx != -1:
            stop_fn_idx = c.find("override fun stop()", start_fn_idx)
            start_body = c[start_fn_idx:stop_fn_idx] if stop_fn_idx != -1 else c[start_fn_idx:]
            srv_idx = start_body.find("gattServer.start()")
            adv_idx = start_body.find("startAdvertising()")
            if srv_idx == -1 or adv_idx == -1 or srv_idx > adv_idx:
                errors.append("BL18: Android gattServer.start() must execute before startAdvertising()")
        else:
            errors.append("BL18: Android BleTransport missing override fun start()")

    # ------------------------------------------------------------------------
    # BL19: iOS privacy (no local name broadcast)
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "CBAdvertisementDataLocalNameKey" in c:
            errors.append("BL19: iOS advertisement must not broadcast local name")

    # ------------------------------------------------------------------------
    # ------------------------------------------------------------------------
    # BL20: Android BleLinkSubstrateTest inventory (Section 16A, 27 methods)
    # ------------------------------------------------------------------------
    if not android_test_substrate_path.exists():
        errors.append(f"BL20: Android test file missing at {android_test_substrate_path}")
    else:
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        req_tests = [
            "testRoleElection_UnsignedLexicographical",
            "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator",
            "testRoleElection_EqualHints_FailClosed",
            "testLinkInfoV1_EncodeDecodeParity",
            "testLinkInfoV1_MalformedLength_Rejected",
            "testLinkInfoV1_UnknownVersion_Rejected",
            "testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid",
            "testRoleElection_CanonicalJsonVectors",
            "testProvisionalConnection_MissingAdvMetadata_Allowed",
            "testLinkInfoAuthority_OverridesAdvMetadata",
            "testBleConnection_ProvisionalStateMachine",
            "testRoleBindingCoordinator_CentralFlow",
            "testRoleBindingCoordinator_PeripheralIncomingWrite",
            "testCrossingConnections_ALessThanB_ARetainsBRejects",
            "testCrossingConnections_BLessThanA_BRetainsARejects",
            "testCrossingConnections_EqualHints_BothReject",
            "testPersistentConnection_MultipleSequentialAttValues",
            "testServerSubscriptionAndMtuTracking",
            "testRecordFragments_ThroughConnectionSeam",
            "testNegotiatedMaxAttValueLength_PropagatedToFragmentation",
            "testDisconnect_PurgesConnectionAndReassemblyState",
            "testRepeatedStartStop_Idempotent",
            "testDataRecord_ForbiddenBeforeReadyState",
            "testLinkLayerReady_RemainsFalse",
            "testSessionManager_HandshakeApiNotInvokedBySubstrate",
            "testDuplexSyntheticTraffic_BothDirections",
            "testSubscriptionAcknowledgement_GatesDuplexReadiness"
        ]
        for t in req_tests:
            if t not in c:
                errors.append(f"BL20: Android test missing method {t}")

    # ------------------------------------------------------------------------
    # BL21: iOS BleLinkSubstrateTests inventory (Section 16B, 28 methods)
    # ------------------------------------------------------------------------
    if not ios_test_substrate_path.exists():
        errors.append(f"BL21: iOS test file missing at {ios_test_substrate_path}")
    else:
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        req_tests = [
            "testRoleElection_UnsignedLexicographical",
            "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator",
            "testRoleElection_EqualHints_FailClosed",
            "testLinkInfoV1_EncodeDecodeParity",
            "testLinkInfoV1_MalformedLength_Rejected",
            "testLinkInfoV1_UnknownVersion_Rejected",
            "testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid",
            "testRoleElection_CanonicalJsonVectors",
            "testProvisionalConnection_MissingAdvMetadata_Allowed",
            "testLinkInfoAuthority_OverridesAdvMetadata",
            "testBleConnection_ProvisionalStateMachine",
            "testRoleBindingCoordinator_CentralFlow",
            "testRoleBindingCoordinator_PeripheralIncomingWrite",
            "testCrossingConnections_ALessThanB_ARetainsBRejects",
            "testCrossingConnections_BLessThanA_BRetainsARejects",
            "testCrossingConnections_EqualHints_BothReject",
            "testCentralWriteQueue_SequentialAttValues",
            "testPeripheralNotificationQueue_Backpressure",
            "testRecordFragments_ThroughConnectionSeam",
            "testNegotiatedMaxAttValueLength_PropagatedToFragmentation",
            "testDisconnect_PurgesConnectionAndReassemblyState",
            "testRepeatedLifecycle_Idempotent",
            "testDataRecord_ForbiddenBeforeReadyState",
            "testLinkLayerReady_RemainsFalse",
            "testSessionManager_HandshakeApiNotInvokedBySubstrate",
            "testDuplexSyntheticTraffic_BothDirections",
            "testLocking_NoDeadlockOnLocalLinkInfoQuery",
            "testSubscriptionAcknowledgement_GatesDuplexReadiness"
        ]
        for t in req_tests:
            if t not in c:
                errors.append(f"BL21: iOS test missing method {t}")

    # ------------------------------------------------------------------------
    # BL22: No production handshake state machine wiring
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        for method in ["beginInitiator", "initiatorProcessHs2", "beginResponder", "responderProcessHs3"]:
            if f"sessions?.{method}" in c or f"sessions.{method}" in c:
                errors.append(f"BL22: Production Android BleTransport must not invoke {method}")

    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        for method in ["beginInitiator", "initiatorProcessHs2", "beginResponder", "responderProcessHs3"]:
            if f"sessions?.{method}" in c or f"sessions.{method}" in c:
                errors.append(f"BL22: Production iOS BleTransport must not invoke {method}")

    # ------------------------------------------------------------------------
    # BL23: Hard boundaries
    # ------------------------------------------------------------------------
    if android_mesh_node_path.exists():
        c = strip_comments(android_mesh_node_path.read_text(encoding="utf-8"))
        if not re.search(r'const\s+val\s+LINK_LAYER_READY\s*=\s*false', c):
            errors.append("BL23: Android LINK_LAYER_READY must remain false")

    if ios_mesh_node_path.exists():
        c = strip_comments(ios_mesh_node_path.read_text(encoding="utf-8"))
        if not re.search(r'public\s+static\s+let\s+linkLayerReady\s*=\s*false', c):
            errors.append("BL23: iOS linkLayerReady must remain false")

    if ios_app_container_path.exists():
        c = strip_comments(ios_app_container_path.read_text(encoding="utf-8"))
        if "import GodstoneMesh" in c:
            errors.append("BL23: AppContainer must remain Archive-only (no GodstoneMesh import)")

    # ------------------------------------------------------------------------
    # BL24: ADR truthful status
    # ------------------------------------------------------------------------
    if adr002_path.exists():
        c = adr002_path.read_text(encoding="utf-8")
        if "C8.4D1-A1" not in c:
            errors.append("BL24: ADR-002 must reflect Phase C8.4D1-A1")

    if adr003_path.exists():
        c = adr003_path.read_text(encoding="utf-8")
        if "C8.4D1-A1" not in c:
            errors.append("BL24: ADR-003 must reflect Phase C8.4D1-A1")

    # ------------------------------------------------------------------------
    # BL25: Android client connection wiring
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "activeClientConnections[address] = client" not in c:
            errors.append("BL25: Android client connection must be retained in activeClientConnections")

    # ------------------------------------------------------------------------
    # BL26: iOS central connection role check
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "roleCoordinator.processCentralEvent" not in c:
            errors.append("BL26: iOS central connection must be governed by roleCoordinator.processCentralEvent")

    # ------------------------------------------------------------------------
    # BL27: Android startup fail-closed gating
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "if (!serverInitiated)" not in c and "if (!serverStarted)" not in c:
            errors.append("BL27: Android BleTransport.start() must check gattServer.start() result")

    # ------------------------------------------------------------------------
    # BL28: Android server CCCD subscription tracking
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "if (subscribedDevices[deviceAddress] != true)" not in c:
            errors.append("BL28: Android BleGattServer.sendNotification must require subscribed client")

    # ------------------------------------------------------------------------
    # BL29: Android server-side MTU callback wired to BleConnection
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if not re.search(r'onMtuChanged\s*=\s*\{[^}]*conn\.maxAttValueLength\s*=\s*maxAttLen', c, re.DOTALL):
            errors.append("BL29: Android BleTransport must update conn.maxAttValueLength on MTU callback")

    # ------------------------------------------------------------------------
    # BL30: iOS outbound write and update queues are strictly hard-bounded
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "maxQueuedAttValues = 16" not in c:
            errors.append("BL30: iOS BleTransport must define maxQueuedAttValues = 16")

    # ------------------------------------------------------------------------
    # BL31: Generated LINK_INFO UUID parity
    # ------------------------------------------------------------------------
    if android_wirev2_path.exists():
        c = strip_comments(android_wirev2_path.read_text(encoding="utf-8"))
        if "LINK_INFO_UUID" not in c or "6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10" not in c:
            errors.append("BL31: Android WireV2 must define generated LINK_INFO_UUID")

    if ios_wirev2_path.exists():
        c = strip_comments(ios_wirev2_path.read_text(encoding="utf-8"))
        if "linkInfoUuidString" not in c or "6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10" not in c:
            errors.append("BL31: iOS WireV2 must define generated linkInfoUuidString")

    # ------------------------------------------------------------------------
    # BL32: No literal LINK_INFO UUID string hardcoded in platform transport code
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10" in c:
            errors.append("BL32: Android BleTransport must reference FrameV2.LINK_INFO_UUID")

    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10" in c:
            errors.append("BL32: iOS BleTransport must reference FrameV2.linkInfoUuidString")

    # ------------------------------------------------------------------------
    # BL33: LinkInfo is not a BleRecord type code
    # ------------------------------------------------------------------------
    if android_record_codec_path.exists():
        c = strip_comments(android_record_codec_path.read_text(encoding="utf-8"))
        if "LINK_INFO" in c:
            errors.append("BL33: LinkInfo must NOT be a BleRecord type in Android BleRecordCodec")

    if ios_record_codec_path.exists():
        c = strip_comments(ios_record_codec_path.read_text(encoding="utf-8"))
        if "linkInfo" in c:
            errors.append("BL33: LinkInfo must NOT be a BleRecord type in iOS BleRecordCodec")

    # ------------------------------------------------------------------------
    # BL34: BleConnectionState defines full lifecycle states
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\benum\s+class\s+BleConnectionState\s*\{[^}]*\bPROVISIONAL_CONNECTING\b', c, re.DOTALL) or not re.search(r'\benum\s+class\s+BleConnectionState\s*\{[^}]*\bROLE_BOUND\b', c, re.DOTALL):
            errors.append("BL34: Android BleConnectionState missing state PROVISIONAL_CONNECTING or ROLE_BOUND")

    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\benum\s+BleConnectionState\b[^}]*\bprovisionalConnecting\b', c, re.DOTALL) or not re.search(r'\benum\s+BleConnectionState\b[^}]*\broleBound\b', c, re.DOTALL):
            errors.append("BL34: iOS BleConnectionState missing state provisionalConnecting or roleBound")

    # ------------------------------------------------------------------------
    # BL35: BleLinkInfoV1 and BleLinkInfoCodec 13-byte layout defined
    # ------------------------------------------------------------------------
    if android_role_path.exists():
        c = strip_comments(android_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleLinkInfoV1\b', c) or "LINK_INFO_BYTES = 13" not in c:
            errors.append("BL35: Android BleLinkInfoV1 / BleLinkInfoConstants missing")

    if ios_role_path.exists():
        c = strip_comments(ios_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\bstruct\s+BleLinkInfoV1\b', c) or "linkInfoBytes = 13" not in c:
            errors.append("BL35: iOS BleLinkInfoV1 / BleLinkInfoConstants missing")

    # ------------------------------------------------------------------------
    # BL36: BleRoleBindingCoordinator parity across Kotlin and Swift
    # ------------------------------------------------------------------------
    if not android_coord_path.exists():
        errors.append(f"BL36: Android BleRoleBindingCoordinator missing at {android_coord_path}")
    else:
        c = strip_comments(android_coord_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleRoleBindingCoordinator\b', c):
            errors.append("BL36: Android BleRoleBindingCoordinator class missing")

    if not ios_coord_path.exists():
        errors.append(f"BL36: iOS BleRoleBindingCoordinator missing at {ios_coord_path}")
    else:
        c = strip_comments(ios_coord_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleRoleBindingCoordinator\b', c):
            errors.append("BL36: iOS BleRoleBindingCoordinator class missing")

    # ------------------------------------------------------------------------
    # BL37: BleLinkInfo reference implementation and vectors
    # ------------------------------------------------------------------------
    if not wire_link_info_ref_path.exists():
        errors.append(f"BL37: BleLinkInfo reference script missing at {wire_link_info_ref_path}")
    if not wire_link_info_vec_path.exists():
        errors.append(f"BL37: BleLinkInfo test vectors missing at {wire_link_info_vec_path}")

    # ------------------------------------------------------------------------
    # BL38: Android BleGattServer onServiceAdded readiness verification
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if not re.search(r'\bonServiceAdded\b', c) or not re.search(r'\bisServiceReady\b', c):
            errors.append("BL38: Android BleGattServer must gate readiness on onServiceAdded callback")

    # ------------------------------------------------------------------------
    # BL39: Android BleGattServer LINK_INFO characteristic READ/WRITE
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if not re.search(r'\bval\s+linkInfoCharUuid\b', c) or not re.search(r'\bonCharacteristicReadRequest\b', c) or not re.search(r'\bonCharacteristicWriteRequest\b', c):
            errors.append("BL39: Android BleGattServer must handle LINK_INFO READ and WRITE requests")

    # ------------------------------------------------------------------------
    # BL40: iOS BleTransport LINK_INFO characteristic READ/WRITE
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if not re.search(r'\blet\s+linkInfoCharacteristicUuid\b', c) or not re.search(r'\bdidReceiveRead\b', c) or not re.search(r'\bdidReceiveWrite\b', c):
            errors.append("BL40: iOS BleTransport must handle LINK_INFO READ and WRITE requests")

    # ------------------------------------------------------------------------
    # BL41: Android GattClient ordered LinkInfo exchange & CCCD descriptor write
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "readCharacteristic(linkInfo)" not in c or "writeDescriptor(cccd)" not in c:
            errors.append("BL41: Android GattClientConnection must read LinkInfo and verify CCCD descriptor write")

    # ------------------------------------------------------------------------
    # BL42: Android BleConnection provisional state machine without mandatory pre-bind nodeHint/role
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\bfun\s+bindRole\b', c) or not re.search(r'\bisRoleBound\b', c):
            errors.append("BL42: Android BleConnection missing bindRole / isRoleBound")

    # ------------------------------------------------------------------------
    # BL43: iOS BleConnection provisional state machine without mandatory pre-bind nodeHint/role
    # ------------------------------------------------------------------------
    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\bfunc\s+bindRole\b', c) or not re.search(r'\bisRoleBound\b', c):
            errors.append("BL43: iOS BleConnection missing bindRole / isRoleBound")

    # ------------------------------------------------------------------------
    # BL44: Application DATA strictly gated before READY state
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if "state != BleConnectionState.READY" not in c:
            errors.append("BL44: Android BleConnection must gate DATA record fragmentation on READY state")

    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if "state != .ready" not in c:
            errors.append("BL44: iOS BleConnection must gate DATA record fragmentation on ready state")

    # ------------------------------------------------------------------------
    # BL45: Separate outbound Central and inbound Peripheral connection namespaces on iOS
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if not re.search(r'\bvar\s+outboundCentralConnections\b', c) or not re.search(r'\bvar\s+inboundPeripheralConnections\b', c):
            errors.append("BL45: iOS BleTransport must separate outboundCentralConnections and inboundPeripheralConnections")

    # ------------------------------------------------------------------------
    # BL46: Android BleTransport snapshot authority derived from real state
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "identity.nodeHint.copyOf(6)" in c:
            errors.append("BL46: Android BleTransport must not use fake nodeHint.copyOf(6) fallback")

    # ------------------------------------------------------------------------
    # BL47: iOS BleTransport non-recursive locking
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "getLocalLinkInfoDataLocked()" not in c:
            errors.append("BL47: iOS BleTransport must define non-recursive getLocalLinkInfoDataLocked()")

    # ------------------------------------------------------------------------
    # BL48: iOS BleTransport CCCD subscription tracking on callback
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "didUpdateNotificationStateFor ch:" not in c:
            errors.append("BL48: iOS BleTransport must track CCCD subscription on didUpdateNotificationStateFor callback")

    # ------------------------------------------------------------------------
    # ------------------------------------------------------------------------
    # BL49: Android GattClient completion-serialized sendAttValue
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if not re.search(r'\bpendingWriteDeferred\b', c) or "WRITE_TYPE_DEFAULT" not in c:
            errors.append("BL49: Android GattClientConnection must serialize sendAttValue with CompletableDeferred")

    # ------------------------------------------------------------------------
    # BL50: Android BleTransport store-backed snapshot authority
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "store.forEachHeldMsgId" not in c and "store?.forEachHeldMsgId" not in c:
            errors.append("BL50: Android BleTransport must derive Bloom digest from durable message store")

    # ------------------------------------------------------------------------
    # BL51: iOS BleTransport store-backed snapshot authority
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "forEachHeldMsgId" not in c or "store" not in c:
            errors.append("BL51: iOS BleTransport must derive Bloom digest from durable message store")

    # ------------------------------------------------------------------------
    # BL52: Android BleTransport RSSI recording from scan observations
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "peerRssi[address] = result.rssi" not in c:
            errors.append("BL52: Android BleTransport must record observed RSSI from scan observations")

    # ------------------------------------------------------------------------
    # BL53: Handshake transport readiness gated on subscription and role binding
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if "isRoleBound && isNotificationSubscribed" not in c:
            errors.append("BL53: Android BleConnection must gate isHandshakeTransportReady on isRoleBound and isNotificationSubscribed")

    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'return\s+_remoteNodeHint\s*!=\s*nil\s*&&\s*_localRole\s*!=\s*nil\s*&&\s*isNotificationSubscribed', c):
            errors.append("BL53: iOS BleConnection must gate isHandshakeTransportReady on isRoleBound and isNotificationSubscribed")

    # ------------------------------------------------------------------------
    # BL54: Connection capacity bounding (max active connections = 7)
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "activeConnections.size >= MAX_ACTIVE_CONNECTIONS" not in c:
            errors.append("BL54: Android BleTransport must bound inbound connections to MAX_ACTIVE_CONNECTIONS")

    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "BleTransport.maxActiveConnections" not in c:
            errors.append("BL54: iOS BleTransport must bound inbound connections to maxActiveConnections")

    # ------------------------------------------------------------------------
    # BL55: iOS provisional lifecycle cleanup timer and didFailToConnect
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "didFailToConnect" not in c or "func purgeCentralConnection(" not in c:
            errors.append("BL55: iOS BleTransport must implement didFailToConnect and purgeCentralConnection")

    # ------------------------------------------------------------------------
    # BL56: Android BleGattServer serviceRegistrationEpoch tracking
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if not re.search(r'\bserviceRegistrationEpoch\b', c):
            errors.append("BL56: Android BleGattServer must track serviceRegistrationEpoch")

    # ------------------------------------------------------------------------
    # BL57: iOS BleTransport backpressure checking canSendWriteWithoutResponse
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "canSendWriteWithoutResponse" not in c:
            errors.append("BL57: iOS BleTransport must check canSendWriteWithoutResponse for write-without-response")

    return errors


def run_selftest() -> int:
    """Mutation testing for all BL01-BL57 control rules."""
    print("Running check_ble_link_substrate_controls selftest (mutation test battery)...")

    # 1. Baseline must pass
    baseline_errors = check_controls()
    if baseline_errors:
        print("FAIL: Baseline check failed with errors:", file=sys.stderr)
        for err in baseline_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    mutations: list[tuple[str, str, str, str]] = [
        # (File to mutate, original snippet, mutant snippet, expected error substring)
        ("android_role", "enum class BleRole", "enum class BleRoleMutated", "BL01"),
        ("ios_role", "enum BleRole: Sendable", "enum BleRoleMutated: Sendable", "BL02"),
        ("android_role", "return BleRoleElectionResult.Tie", "return BleRoleElectionResult.Elected(BleRole.INITIATOR)", "BL03"),
        ("ios_role", "return .tie", "return .elected(.initiator)", "BL04"),
        ("android_role", "object BleDiscoveryConstants {\n    const val DISCOVERY_PAYLOAD_BYTES = 13", "object BleDiscoveryConstants {\n    const val DISCOVERY_PAYLOAD_BYTES = 26", "BL05"),
        ("ios_role", "enum BleDiscoveryConstants {\n    public static let discoveryPayloadBytes = 13", "enum BleDiscoveryConstants {\n    public static let discoveryPayloadBytes = 26", "BL06"),
        ("android_conn", "class BleConnection(", "class BleConnectionMutated(", "BL07"),
        ("ios_conn", "class BleConnection", "class BleConnectionMutated", "BL08"),
        ("android_client", "class GattClientConnection", "class GattClientConnectionMutated", "BL09"),
        ("android_server", "class BleGattServer", "class BleGattServerMutated", "BL10"),
        ("ios_transport", "peripheral.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj])", "/* peripheral.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj]) */", "BL11"),
        ("android_transport", "val roleCoordinator = BleRoleBindingCoordinator", "val roleCoordinatorMutated = BleRoleBindingCoordinator", "BL12"),
        ("ios_transport", "public private(set) var roleCoordinator: BleRoleBindingCoordinator", "public private(set) var roleCoordinatorMutated: BleRoleBindingCoordinator", "BL13"),
        ("android_transport", "conn.markDisconnected()", "/* conn.markDisconnected() */", "BL14"),
        ("ios_transport", "outboundCentralConnections.removeAll()", "/* outboundCentralConnections.removeAll() */", "BL15"),
        ("android_transport", "MAX_DISCOVERED_PEERS = 64", "MAX_DISCOVERED_PEERS = 9999", "BL16"),
        ("ios_transport", "maxDiscoveredPeers = 64", "maxDiscoveredPeers = 9999", "BL17"),
        ("android_transport", "val serverInitiated = gattServer.start()", "startAdvertising()\n        val serverInitiated = gattServer.start()", "BL18"),
        ("ios_transport", "[BleTransport.serviceUuid]", "[BleTransport.serviceUuid],\n            CBAdvertisementDataLocalNameKey: \"GS\"", "BL19"),
        ("android_test_substrate", "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator", "disabled_testRoleElection", "BL20"),
        ("ios_test_substrate", "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator", "disabled_testRoleElection", "BL21"),
        ("android_transport", "sessions?.seal(peerId, bytes)", "sessions?.beginInitiator(peerId, bytes)", "BL22"),
        ("ios_transport", "sessions?.seal(peerId, frame.encode())", "sessions?.beginInitiator(peerId, frame.encode())", "BL22"),
        ("android_mesh_node", "const val LINK_LAYER_READY = false", "const val LINK_LAYER_READY = true", "BL23"),
        ("ios_mesh_node", "public static let linkLayerReady = false", "public static let linkLayerReady = true", "BL23"),
        ("ios_app_container", "import Foundation", "import Foundation\nimport GodstoneMesh", "BL23"),
        ("adr002", "C8.4D1-A1", "C8.4D1-MUTATED", "BL24"),
        ("adr003", "C8.4D1-A1", "C8.4D1-MUTATED", "BL24"),
        ("android_transport", "activeClientConnections[address] = client", "/* activeClientConnections[address] = client */", "BL25"),
        ("ios_transport", "roleCoordinator.processCentralEvent", "fakeCoordinator.processCentralEvent", "BL26"),
        ("android_transport", "if (!serverInitiated)", "if (false)", "BL27"),
        ("android_server", "if (subscribedDevices[deviceAddress] != true)", "if (false)", "BL28"),
        ("android_transport", "conn.maxAttValueLength = maxAttLen", "/* conn.maxAttValueLength = maxAttLen */", "BL29"),
        ("ios_transport", "maxQueuedAttValues = 16", "maxQueuedAttValues = 999999", "BL30"),
        ("android_wirev2", "val LINK_INFO_UUID: java.util.UUID = java.util.UUID.fromString(\"6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10\")", "/* removed LINK_INFO_UUID */", "BL31"),
        ("ios_wirev2", "public static let linkInfoUuidString = \"6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10\"", "/* removed linkInfoUuidString */", "BL31"),
        ("android_transport", "val LINK_INFO_CHAR_UUID: UUID = FrameV2.LINK_INFO_UUID", "val LINK_INFO_CHAR_UUID: UUID = UUID.fromString(\"6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10\")", "BL32"),
        ("ios_transport", "public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)", "public static let linkInfoCharacteristicUuid = CBUUID(string: \"6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10\")", "BL32"),
        ("android_record_codec", "CLOSE(0x21.toByte());", "CLOSE(0x21.toByte()),\n    LINK_INFO(0x22.toByte());", "BL33"),
        ("ios_record_codec", "case close = 0x21", "case close = 0x21\n    case linkInfo = 0x22", "BL33"),
        ("android_conn", "PROVISIONAL_CONNECTING,", "/* PROVISIONAL_CONNECTING, */", "BL34"),
        ("ios_conn", "case provisionalConnecting", "/* case provisionalConnecting */", "BL34"),
        ("android_role", "class BleLinkInfoV1", "class BleLinkInfoV1Mutated", "BL35"),
        ("ios_role", "struct BleLinkInfoV1: Equatable", "struct BleLinkInfoV1Mutated: Equatable", "BL35"),
        ("android_coord", "class BleRoleBindingCoordinator(", "class BleRoleBindingCoordinatorMutated(", "BL36"),
        ("ios_coord", "public final class BleRoleBindingCoordinator:", "public final class BleRoleBindingCoordinatorMutated:", "BL36"),
        ("android_server", "override fun onServiceAdded(status: Int, service: BluetoothGattService) {", "override fun onServiceAddedMutated(status: Int, service: BluetoothGattService) {", "BL38"),
        ("android_server", "private val linkInfoCharUuid: UUID = BleTransport.LINK_INFO_CHAR_UUID", "private val linkInfoCharUuidMutated: UUID = BleTransport.LINK_INFO_CHAR_UUID", "BL39"),
        ("ios_transport", "public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)", "public static let linkInfoCharacteristicUuidMutated = CBUUID(string: FrameV2.linkInfoUuidString)", "BL40"),
        ("android_client", "readCharacteristic(linkInfo)", "readCharacteristic(null)", "BL41"),
        ("android_conn", "fun bindRole(", "fun bindRoleMutated(", "BL42"),
        ("ios_conn", "func bindRole(", "func bindRoleMutated(", "BL43"),
        ("android_conn", "state != BleConnectionState.READY", "state != BleConnectionState.CLOSED", "BL44"),
        ("ios_conn", "state != .ready", "state != .closed", "BL44"),
        ("ios_transport", "private var outboundCentralConnections: [UUID: BleConnection] = [:]", "private var outboundCentralConnectionsMutated: [UUID: BleConnection] = [:]", "BL45"),
        ("android_transport", "bloom.toBytes().copyOf(BleLinkInfoConstants.SHORT_DIGEST_BYTES)", "identity.nodeHint.copyOf(6)", "BL46"),
        ("ios_transport", "getLocalLinkInfoDataLocked()", "getLocalLinkInfoDataLockedMutated()", "BL47"),
        ("ios_transport", "didUpdateNotificationStateFor ch: CBCharacteristic,", "didUpdateNotificationStateForMutated ch: CBCharacteristic,", "BL48"),
        ("android_client", "pendingWriteDeferred", "pendingWriteDeferredMut", "BL49"),
        ("android_transport", "store.forEachHeldMsgId", "/* store.forEachHeldMsgId */", "BL50"),
        ("ios_transport", "s.forEachHeldMsgId", "/* s.forEachHeldMsgId */", "BL51"),
        ("android_transport", "peerRssi[address] = result.rssi", "/* peerRssi[address] = result.rssi */", "BL52"),
        ("android_conn", "isRoleBound && isNotificationSubscribed", "isRoleBound", "BL53"),
        ("ios_conn", "_remoteNodeHint != nil && _localRole != nil && isNotificationSubscribed", "_remoteNodeHint != nil && _localRole != nil", "BL53"),
        ("android_transport", "activeConnections.size >= MAX_ACTIVE_CONNECTIONS", "false", "BL54"),
        ("ios_transport", "BleTransport.maxActiveConnections", "999999", "BL54"),
        ("ios_transport", "func purgeCentralConnection(", "func purgeCentralConnectionMutated(", "BL55"),
        ("android_server", "serviceRegistrationEpoch", "serviceRegistrationEpochMut", "BL56"),
        ("ios_transport", "p.canSendWriteWithoutResponse", "true", "BL57"),
    ]

    all_passed = True
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)

        file_map = {
            "android_role": ANDROID_ROLE_PATH,
            "android_coord": ANDROID_COORD_PATH,
            "android_conn": ANDROID_CONN_PATH,
            "android_client": ANDROID_CLIENT_PATH,
            "android_server": ANDROID_SERVER_PATH,
            "android_transport": ANDROID_TRANSPORT_PATH,
            "android_test_substrate": ANDROID_TEST_SUBSTRATE_PATH,
            "android_mesh_node": ANDROID_MESH_NODE_PATH,
            "android_wirev2": ANDROID_WIREV2_PATH,
            "android_record_codec": ANDROID_RECORD_CODEC_PATH,
            "ios_role": IOS_ROLE_PATH,
            "ios_coord": IOS_COORD_PATH,
            "ios_conn": IOS_CONN_PATH,
            "ios_transport": IOS_TRANSPORT_PATH,
            "ios_test_substrate": IOS_TEST_SUBSTRATE_PATH,
            "ios_mesh_node": IOS_MESH_NODE_PATH,
            "ios_app_container": IOS_APP_CONTAINER_PATH,
            "ios_wirev2": IOS_WIREV2_PATH,
            "ios_record_codec": IOS_RECORD_CODEC_PATH,
            "wire_link_info_ref": WIRE_LINK_INFO_REF_PATH,
            "wire_link_info_vec": WIRE_LINK_INFO_VEC_PATH,
            "adr002": ADR002_PATH,
            "adr003": ADR003_PATH,
        }

        tmp_files: dict[str, Path] = {}
        for key, orig in file_map.items():
            t = tmp_path / orig.name
            t.write_text(orig.read_text(encoding="utf-8"), encoding="utf-8")
            tmp_files[key] = t

        for file_key, orig_str, mut_str, expected_err in mutations:
            target = tmp_files[file_key]
            orig_content = target.read_text(encoding="utf-8")
            if orig_str not in orig_content:
                print(f"FAIL: Mutation snippet not found in {file_key}: {orig_str!r}", file=sys.stderr)
                all_passed = False
                continue

            mut_content = orig_content.replace(orig_str, mut_str)
            target.write_text(mut_content, encoding="utf-8")

            errs = check_controls(
                android_role_path=tmp_files["android_role"],
                android_coord_path=tmp_files["android_coord"],
                android_conn_path=tmp_files["android_conn"],
                android_client_path=tmp_files["android_client"],
                android_server_path=tmp_files["android_server"],
                android_transport_path=tmp_files["android_transport"],
                android_test_substrate_path=tmp_files["android_test_substrate"],
                android_mesh_node_path=tmp_files["android_mesh_node"],
                android_wirev2_path=tmp_files["android_wirev2"],
                android_record_codec_path=tmp_files["android_record_codec"],
                ios_role_path=tmp_files["ios_role"],
                ios_coord_path=tmp_files["ios_coord"],
                ios_conn_path=tmp_files["ios_conn"],
                ios_transport_path=tmp_files["ios_transport"],
                ios_test_substrate_path=tmp_files["ios_test_substrate"],
                ios_mesh_node_path=tmp_files["ios_mesh_node"],
                ios_app_container_path=tmp_files["ios_app_container"],
                ios_wirev2_path=tmp_files["ios_wirev2"],
                ios_record_codec_path=tmp_files["ios_record_codec"],
                wire_link_info_ref_path=tmp_files["wire_link_info_ref"],
                wire_link_info_vec_path=tmp_files["wire_link_info_vec"],
                adr002_path=tmp_files["adr002"],
                adr003_path=tmp_files["adr003"],
            )

            # Revert mutation
            target.write_text(orig_content, encoding="utf-8")

            caught = any(expected_err in e for e in errs)
            if not caught:
                print(f"FAIL: Mutation {file_key} [{orig_str!r} -> {mut_str!r}] was NOT caught by {expected_err}", file=sys.stderr)
                all_passed = False
            else:
                print(f"  [ok] Mutation {file_key} caught by {expected_err}")

    if all_passed:
        print(f"All {len(mutations)} mutations caught deterministically.")
        return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="Run negative mutation self-test battery")
    args = parser.parse_args()

    if args.selftest:
        return run_selftest()

    errors = check_controls()
    if errors:
        print("BLE link substrate structural control violations found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("BLE link substrate structural controls: ALL PASSED (BL01-BL57).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
