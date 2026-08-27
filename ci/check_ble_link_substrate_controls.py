#!/usr/bin/env python3
"""Structural and regression controls for Persistent Duplex BLE Link Substrate & Role Election (ADR-002, Phase C8.4D1).

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
- BL12: Android BleTransport retains real advertised nodeHint and evaluates role election
- BL13: iOS BleTransport retains real advertised nodeHint and evaluates role election
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
- BL24: ADR-002 and ADR-003 truthful representation of Phase C8.4D1 status
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Paths
ANDROID_ROLE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRoleElection.kt"
ANDROID_CONN_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleConnection.kt"
ANDROID_CLIENT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "GattClient.kt"
ANDROID_SERVER_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "GattServer.kt"
ANDROID_TRANSPORT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleTransport.kt"
ANDROID_TEST_SUBSTRATE_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleLinkSubstrateTest.kt"
ANDROID_MESH_NODE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "MeshNode.kt"

IOS_ROLE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRoleElection.swift"
IOS_CONN_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleConnection.swift"
IOS_TRANSPORT_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleTransport.swift"
IOS_TEST_SUBSTRATE_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "BleLinkSubstrateTests.swift"
IOS_MESH_NODE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshNode.swift"
IOS_APP_CONTAINER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "App" / "AppContainer.swift"

ADR002_PATH = ROOT / "docs" / "adr" / "ADR-002-ble-record-layer.md"
ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"


def strip_comments(text: str) -> str:
    """Remove single-line and multi-line comments."""
    text = re.sub(r'//.*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def check_controls(
    android_role_path: Path = ANDROID_ROLE_PATH,
    android_conn_path: Path = ANDROID_CONN_PATH,
    android_client_path: Path = ANDROID_CLIENT_PATH,
    android_server_path: Path = ANDROID_SERVER_PATH,
    android_transport_path: Path = ANDROID_TRANSPORT_PATH,
    android_test_substrate_path: Path = ANDROID_TEST_SUBSTRATE_PATH,
    android_mesh_node_path: Path = ANDROID_MESH_NODE_PATH,
    ios_role_path: Path = IOS_ROLE_PATH,
    ios_conn_path: Path = IOS_CONN_PATH,
    ios_transport_path: Path = IOS_TRANSPORT_PATH,
    ios_test_substrate_path: Path = IOS_TEST_SUBSTRATE_PATH,
    ios_mesh_node_path: Path = IOS_MESH_NODE_PATH,
    ios_app_container_path: Path = IOS_APP_CONTAINER_PATH,
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
        if not re.search(r'\bobject\s+BleDiscoveryCodec\b', c) or "DISCOVERY_PAYLOAD_BYTES = 13" not in c:
            errors.append("BL05: Android BleDiscoveryCodec 13-byte payload codec missing")

    # ------------------------------------------------------------------------
    # BL06: iOS BleDiscoveryCodec 13-byte payload
    # ------------------------------------------------------------------------
    if ios_role_path.exists():
        c = strip_comments(ios_role_path.read_text(encoding="utf-8"))
        if not re.search(r'\benum\s+BleDiscoveryCodec\b', c) or "discoveryPayloadBytes = 13" not in c:
            errors.append("BL06: iOS BleDiscoveryCodec 13-byte payload codec missing")

    # ------------------------------------------------------------------------
    # BL07: Android BleConnection persistent abstraction
    # ------------------------------------------------------------------------
    if not android_conn_path.exists():
        errors.append(f"BL07: Android BleConnection missing at {android_conn_path}")
    else:
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if not re.search(r'\bclass\s+BleConnection\b', c):
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
        if "updateValue" not in c or "onSubscribedCentrals" not in c:
            errors.append("BL11: iOS updateValue with onSubscribedCentrals missing")
        if "peripheralManagerIsReady" not in c:
            errors.append("BL11: iOS peripheralManagerIsReady backpressure handling missing")

    # ------------------------------------------------------------------------
    # BL12: Android BleTransport role election & hint retention
    # ------------------------------------------------------------------------
    if not android_transport_path.exists():
        errors.append(f"BL12: Android BleTransport missing at {android_transport_path}")
    else:
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "BleRoleElection.elect(" not in c:
            errors.append("BL12: Android BleTransport missing BleRoleElection.elect")

    # ------------------------------------------------------------------------
    # BL13: iOS BleTransport role election & hint retention
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "BleRoleElection.elect(" not in c:
            errors.append("BL13: iOS BleTransport missing BleRoleElection.elect")

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
        if "conn.markDisconnected()" not in c:
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
        srv_idx = c.find("gattServer.start()")
        adv_idx = c.find("startAdvertising()")
        if srv_idx == -1 or adv_idx == -1 or srv_idx > adv_idx:
            errors.append("BL18: Android gattServer.start() must execute before startAdvertising()")

    # ------------------------------------------------------------------------
    # BL19: iOS privacy (no local name broadcast)
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "CBAdvertisementDataLocalNameKey" in c:
            errors.append("BL19: iOS advertisement must not broadcast local name")

    # ------------------------------------------------------------------------
    # BL20: Android BleLinkSubstrateTest inventory
    # ------------------------------------------------------------------------
    if not android_test_substrate_path.exists():
        errors.append(f"BL20: Android test file missing at {android_test_substrate_path}")
    else:
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        req_tests = [
            "testRoleElection_UnsignedLexicographical",
            "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator",
            "testRoleElection_EqualHints_FailClosed",
            "testDiscoveryPayload_EncodeDecodeRoundTrip",
            "testScanObservationMerger_AdvFirst_ScanResponseLater",
            "testPersistentConnection_MultipleSequentialAttValues",
            "testDuplexSyntheticTraffic_BothDirections",
            "testRecordFragments_ThroughConnectionSeam",
            "testNegotiatedMaxAttValueLength_PropagatedToFragmentation",
            "testDisconnect_PurgesConnectionAndReassemblyState",
            "testRepeatedStartStop_Idempotent",
            "testSessionManager_HandshakeApiNotInvokedBySubstrate",
            "testLinkLayerReady_RemainsFalse",
        ]
        for t in req_tests:
            if t not in c:
                errors.append(f"BL20: Android test missing method {t}")

    # ------------------------------------------------------------------------
    # BL21: iOS BleLinkSubstrateTests inventory
    # ------------------------------------------------------------------------
    if not ios_test_substrate_path.exists():
        errors.append(f"BL21: iOS test file missing at {ios_test_substrate_path}")
    else:
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        req_tests = [
            "testRoleElection_UnsignedLexicographical",
            "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator",
            "testRoleElection_EqualHints_FailClosed",
            "testDiscoveryPayload_EncodeDecodeRoundTrip",
            "testCentralWriteQueue_SequentialAttValues",
            "testPeripheralNotificationQueue_Backpressure",
            "testDuplexSyntheticTraffic_BothDirections",
            "testRecordFragments_ThroughConnectionSeam",
            "testNegotiatedMaxAttValueLength_PropagatedToFragmentation",
            "testDisconnect_PurgesConnectionAndReassemblyState",
            "testRepeatedLifecycle_Idempotent",
            "testSessionManager_HandshakeApiNotInvokedBySubstrate",
            "testLinkLayerReady_RemainsFalse",
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
        if "GodstoneMesh" in c or "BleTransport" in c:
            errors.append("BL23: iOS AppContainer must remain Archive-only (Mesh absent)")

    # ------------------------------------------------------------------------
    # BL24: ADR-002 and ADR-003 Status Consistency
    # ------------------------------------------------------------------------
    if adr002_path.exists():
        c_adr2 = adr002_path.read_text(encoding="utf-8")
        if not re.search(r'PHASE\s+C8\.4D1', c_adr2):
            errors.append("BL24: ADR-002 missing C8.4D1 status documentation")

    if adr003_path.exists():
        c_adr3 = adr003_path.read_text(encoding="utf-8")
        if not re.search(r'Phase\s+C8\.4D1', c_adr3):
            errors.append("BL24: ADR-003 missing C8.4D1 status documentation")

    return errors


def run_selftest() -> int:
    """Mutation testing for all BL01-BL24 control rules."""
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
        ("android_role", "DISCOVERY_PAYLOAD_BYTES = 13", "DISCOVERY_PAYLOAD_BYTES = 26", "BL05"),
        ("ios_role", "discoveryPayloadBytes = 13", "discoveryPayloadBytes = 26", "BL06"),
        ("android_conn", "class BleConnection", "class BleConnectionMutated", "BL07"),
        ("ios_conn", "class BleConnection", "class BleConnectionMutated", "BL08"),
        ("android_client", "class GattClientConnection", "class GattClientConnectionMutated", "BL09"),
        ("android_server", "class BleGattServer", "class BleGattServerMutated", "BL10"),
        ("ios_transport", "onSubscribedCentrals", "onSubscribersMutated", "BL11"),
        ("android_transport", "BleRoleElection.elect(identity.nodeHint", "BleRoleElection.electFake(identity.nodeHint", "BL12"),
        ("ios_transport", "BleRoleElection.elect(localHint:", "BleRoleElection.electFake(localHint:", "BL13"),
        ("android_transport", "conn.markDisconnected()", "/* conn.markDisconnected() */", "BL14"),
        ("ios_transport", "conn.markDisconnected()", "/* conn.markDisconnected() */", "BL15"),
        ("android_transport", "MAX_DISCOVERED_PEERS = 64", "MAX_DISCOVERED_PEERS = 9999", "BL16"),
        ("ios_transport", "maxDiscoveredPeers = 64", "maxDiscoveredPeers = 9999", "BL17"),
        ("android_transport", "gattServer.start()\n        startAdvertising()", "startAdvertising()\n        gattServer.start()", "BL18"),
        ("ios_transport", "[BleTransport.serviceUuid]", "[BleTransport.serviceUuid],\n            CBAdvertisementDataLocalNameKey: \"GS\"", "BL19"),
        ("android_test_substrate", "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator", "disabled_testRoleElection", "BL20"),
        ("ios_test_substrate", "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator", "disabled_testRoleElection", "BL21"),
        ("android_transport", "sessions?.seal(peerId, bytes)", "sessions?.beginInitiator(peerId, bytes)", "BL22"),
        ("ios_transport", "sessions?.seal(peerId, frame.encode())", "sessions?.beginInitiator(peerId, frame.encode())", "BL22"),
        ("android_mesh_node", "const val LINK_LAYER_READY = false", "const val LINK_LAYER_READY = true", "BL23"),
        ("ios_mesh_node", "public static let linkLayerReady = false", "public static let linkLayerReady = true", "BL23"),
        ("ios_app_container", "import Foundation", "import Foundation\nimport GodstoneMesh", "BL23"),
        ("adr002", "PHASE C8.4D1", "PHASE C8.4X_MUTATED", "BL24"),
        ("adr003", "Phase C8.4D1", "Phase C8.4X_MUTATED", "BL24"),
    ]

    all_passed = True
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)

        file_map = {
            "android_role": ANDROID_ROLE_PATH,
            "android_conn": ANDROID_CONN_PATH,
            "android_client": ANDROID_CLIENT_PATH,
            "android_server": ANDROID_SERVER_PATH,
            "android_transport": ANDROID_TRANSPORT_PATH,
            "android_test_substrate": ANDROID_TEST_SUBSTRATE_PATH,
            "android_mesh_node": ANDROID_MESH_NODE_PATH,
            "ios_role": IOS_ROLE_PATH,
            "ios_conn": IOS_CONN_PATH,
            "ios_transport": IOS_TRANSPORT_PATH,
            "ios_test_substrate": IOS_TEST_SUBSTRATE_PATH,
            "ios_mesh_node": IOS_MESH_NODE_PATH,
            "ios_app_container": IOS_APP_CONTAINER_PATH,
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
                android_conn_path=tmp_files["android_conn"],
                android_client_path=tmp_files["android_client"],
                android_server_path=tmp_files["android_server"],
                android_transport_path=tmp_files["android_transport"],
                android_test_substrate_path=tmp_files["android_test_substrate"],
                android_mesh_node_path=tmp_files["android_mesh_node"],
                ios_role_path=tmp_files["ios_role"],
                ios_conn_path=tmp_files["ios_conn"],
                ios_transport_path=tmp_files["ios_transport"],
                ios_test_substrate_path=tmp_files["ios_test_substrate"],
                ios_mesh_node_path=tmp_files["ios_mesh_node"],
                ios_app_container_path=tmp_files["ios_app_container"],
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

    print("BLE link substrate structural controls: ALL PASSED (BL01-BL24).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
