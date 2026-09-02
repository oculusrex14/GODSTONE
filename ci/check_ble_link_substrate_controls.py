#!/usr/bin/env python3
"""Structural and regression controls for Persistent Duplex BLE Link Substrate & Role Election (ADR-002, Phase C8.4D1-R2/R2.2).

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
- BL24: ADR-002 and ADR-003 truthful representation of Phase C8.4D1-A1 and C8.4D1-R2/R2.2 status
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
- BL38: Android BleGattServer onServiceAdded readiness callback enforcement with generation and service identity match
- BL39: Android BleGattServer LINK_INFO characteristic READ/WRITE support
- BL40: iOS BleTransport LINK_INFO characteristic READ/WRITE support
- BL41: Android GattClient ordered LinkInfo exchange & CCCD descriptor status verification
- BL42: Android BleConnection provisional state machine without mandatory pre-bind nodeHint/role & bindRole
- BL43: iOS BleConnection provisional state machine without mandatory pre-bind nodeHint/role & bindRole
- BL44: Application DATA strictly gated before READY state on Android and iOS
- BL45: Separate outbound Central and inbound Peripheral connection namespaces on iOS
- BL46: Android BleTransport snapshot authority derived from real state without synthetic fallback
- BL47: iOS BleTransport snapshot authority with thread-safe precomputed snapshot caching
- BL48: iOS BleTransport CCCD subscription tracking on didUpdateNotificationStateFor
- BL49: Android GattClientConnection typed pending operations with generation matching
- BL50: Android LinkInfoSnapshotAuthority backed by real store enumeration and saturating 255
- BL51: iOS LinkInfoSnapshotAuthority backed by real store enumeration and saturating 255
- BL52: Android BleTransport records observed RSSI from scan observations without synthetic 0 fallback
- BL53: Physical duplex readiness gated on both role binding and notification subscription
- BL54: Connection capacity bounding (MAX_ACTIVE_CONNECTIONS = 7, maxActiveConnections = 7)
- BL55: iOS provisional timer with generation isolation and didFailToConnect
- BL56: Android BleGattServer service registration generation and notification callback generation isolation
- BL57: iOS BleTransport backpressure checking canSendWriteWithoutResponse
- BL58: Authoritative Peer Publication gated on duplex transport readiness
- BL59: ATT READ callbacks serve from precomputed immutable cache without synchronous durable store traversal
- BL60: Direct canonical JSON test vector consumption from wire/ble_link_info_vectors.json
- BL61: iOS inbound central subscription authority requiring active accepted inbound connection
- BL62: Android BleServerOrchestrationDriver onNotificationSent signature
- BL63: Android BleServerOrchestrationDriver server callback epoch poisoning
- BL64: Android BleServerOrchestrationDriver onServiceAdded matching
- BL65: Android BleGlobalCapacityAuthority
- BL66: iOS BleGlobalCapacityAuthority
- BL67: Android BleTransport centralDriver instantiation
- BL68: Android BleGattServer orchestrationDriver integration
- BL69: iOS BleCentralOrchestrationDriver CoreBluetooth callbacks
- BL70: iOS BlePeripheralOrchestrationDriver CoreBluetooth callbacks
- BL71: iOS BleTransport driver instantiation
- BL72: iOS BleTransport callback delegation
- BL73: Android LinkInfoSnapshotAuthority pure cache reads
- BL74: iOS LinkInfoSnapshotAuthority pure atomic cache reads
- BL75: Android SqliteDeliveryRepository onHeldSetMutated invocation
- BL76: Android MeshModule wiring
- BL77: iOS MessageStore notifyHeldSetChanged
- BL78: ADR-002 truthful status
- BL79: ADR-003 truthful status
- BL80: Substrate test inventories
- BL81: Android UUID-only discovery scan authority
- BL82: Android Server physical link direction isolation
- BL83: Android Inbound Responder metadata propagation
- BL84: iOS Non-allocating LinkInfo read
- BL85: iOS Inbound pre-subscription timeout
- BL86: Real Android server callback factory
- BL87: Thread-safe capacity authority leases
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
ANDROID_DRIVER_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleOrchestrationDriver.kt"
ANDROID_CAPACITY_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleGlobalCapacityAuthority.kt"
ANDROID_DELIVERY_REPO_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "delivery" / "SqliteDeliveryRepository.kt"
ANDROID_MESH_MODULE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "di" / "MeshModule.kt"
ANDROID_TRANSPORT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleTransport.kt"
ANDROID_SNAPSHOT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "LinkInfoSnapshotAuthority.kt"
ANDROID_TEST_SUBSTRATE_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleLinkSubstrateTest.kt"
ANDROID_MESH_NODE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "MeshNode.kt"
ANDROID_WIREV2_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "wire" / "v2" / "WireV2.kt"
ANDROID_RECORD_CODEC_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRecord.kt"

IOS_ROLE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRoleElection.swift"
IOS_COORD_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRoleBindingCoordinator.swift"
IOS_CONN_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleConnection.swift"
IOS_DRIVER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleOrchestrationDriver.swift"
IOS_TRANSPORT_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleTransport.swift"
IOS_SNAPSHOT_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "LinkInfoSnapshotAuthority.swift"
IOS_MESSAGE_STORE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MessageStore.swift"
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
    android_driver_path: Path = ANDROID_DRIVER_PATH,
    android_capacity_path: Path = ANDROID_CAPACITY_PATH,
    android_delivery_repo_path: Path = ANDROID_DELIVERY_REPO_PATH,
    android_mesh_module_path: Path = ANDROID_MESH_MODULE_PATH,
    android_transport_path: Path = ANDROID_TRANSPORT_PATH,
    android_snapshot_path: Path = ANDROID_SNAPSHOT_PATH,
    android_test_substrate_path: Path = ANDROID_TEST_SUBSTRATE_PATH,
    android_mesh_node_path: Path = ANDROID_MESH_NODE_PATH,
    android_wirev2_path: Path = ANDROID_WIREV2_PATH,
    android_record_codec_path: Path = ANDROID_RECORD_CODEC_PATH,
    ios_role_path: Path = IOS_ROLE_PATH,
    ios_coord_path: Path = IOS_COORD_PATH,
    ios_conn_path: Path = IOS_CONN_PATH,
    ios_driver_path: Path = IOS_DRIVER_PATH,
    ios_transport_path: Path = IOS_TRANSPORT_PATH,
    ios_snapshot_path: Path = IOS_SNAPSHOT_PATH,
    ios_message_store_path: Path = IOS_MESSAGE_STORE_PATH,
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
        if "g !== gatt" not in c or "gattGeneration" not in c:
            errors.append("BL09: Android GattClientConnection must verify g !== gatt and gattGeneration")

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
        if "peripheral.updateValue(" not in c and "peripheral?.updateValue(" not in c:
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
        if "conn?.markDisconnected()" not in c:
            errors.append("BL14: Android BleTransport missing conn?.markDisconnected() teardown")

    # ------------------------------------------------------------------------
    # BL15: iOS BleTransport connection teardown
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "outboundCentralConnections.removeAll()" not in c:
            errors.append("BL15: iOS BleTransport missing outboundCentralConnections.removeAll() teardown")

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
            "testLinkInfoV1_EncodeDecodeParity",
            "testLinkInfoV1_MalformedLength_Rejected",
            "testLinkInfoV1_UnknownVersion_Rejected",
            "testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid",
            "testRoleElection_CanonicalJsonVectors",
            "testStateProgression_InitiatorFlow_Authoritative",
            "testStateProgression_ResponderFlow_Authoritative",
            "testRoleBinding_NegativePreconditions",
            "testTransitionToReady_ForbiddenInSubstrate",
            "testDataTransmission_StrictlyForbiddenBeforeReady",
            "testLinkInfoSnapshotAuthority_EmptyStore",
            "testLinkInfoSnapshotAuthority_HeldRecordsAndSaturating255",
            "testCrossingConnections_ALessThanB_ARetainsBRejects",
            "testCrossingConnections_BLessThanA_BRetainsARejects",
            "testCrossingConnections_EqualHints_BothReject",
            "testHandshakeRecordDelivery_AcrossConnectionSeam",
            "testDisconnect_PurgesState_AndIdempotent",
            "testLinkLayerReady_RemainsFalse",
            "testSessionManager_HandshakeApiNotInvokedBySubstrate"
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
            "testLinkInfoV1_EncodeDecodeParity",
            "testLinkInfoV1_MalformedLength_Rejected",
            "testLinkInfoV1_UnknownVersion_Rejected",
            "testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid",
            "testRoleElection_CanonicalJsonVectors",
            "testStateProgression_InitiatorFlow_Authoritative",
            "testStateProgression_ResponderFlow_Authoritative",
            "testRoleBinding_NegativePreconditions",
            "testTransitionToReady_ForbiddenInSubstrate",
            "testDataTransmission_StrictlyForbiddenBeforeReady",
            "testLinkInfoSnapshotAuthority_EmptyStore",
            "testLinkInfoSnapshotAuthority_HeldRecordsAndSaturating255",
            "testCrossingConnections_ALessThanB_ARetainsBRejects",
            "testCrossingConnections_BLessThanA_BRetainsARejects",
            "testCrossingConnections_EqualHints_BothReject",
            "testHandshakeRecordDelivery_AcrossConnectionSeam",
            "testDisconnect_PurgesState_AndIdempotent",
            "testLinkLayerReady_RemainsFalse"
        ]
        for t in req_tests:
            if t not in c:
                errors.append(f"BL21: iOS test missing method {t}")

    # ------------------------------------------------------------------------
    # BL22: No production handshake API calls in substrate drivers
    # ------------------------------------------------------------------------
    forbidden_handshake_apis = [
        "beginInitiator",
        "initiatorStart",
        "initiatorProcessHs2",
        "beginResponder",
        "responderProcessHs1",
        "responderProcessHs3"
    ]
    for name, p in [("Android transport", android_transport_path), ("iOS transport", ios_transport_path)]:
        if p.exists():
            c = strip_comments(p.read_text(encoding="utf-8"))
            for api in forbidden_handshake_apis:
                if f".{api}(" in c or f" {api}(" in c:
                    errors.append(f"BL22: {name} must NOT call production SessionManager handshake API '{api}'")

    # ------------------------------------------------------------------------
    # BL23: Link layer remains disabled
    # ------------------------------------------------------------------------
    if android_mesh_node_path.exists():
        c = strip_comments(android_mesh_node_path.read_text(encoding="utf-8"))
        if "const val LINK_LAYER_READY = false" not in c:
            errors.append("BL23: Android MeshNode.LINK_LAYER_READY must remain false")

    if ios_mesh_node_path.exists():
        c = strip_comments(ios_mesh_node_path.read_text(encoding="utf-8"))
        if "public static let linkLayerReady = false" not in c:
            errors.append("BL23: iOS MeshNode.linkLayerReady must remain false")

    if ios_app_container_path.exists():
        c = strip_comments(ios_app_container_path.read_text(encoding="utf-8"))
        if "GodstoneMesh" in c or "BoundRecipientKeyResolver" in c or "TrustedHandshakeController" in c:
            errors.append("BL23: iOS AppContainer must not import GodstoneMesh or reference mesh handshake symbols")

    # ------------------------------------------------------------------------
    # BL24: ADR status and scope integrity
    # ------------------------------------------------------------------------
    if adr002_path.exists():
        c = adr002_path.read_text(encoding="utf-8")
        if "C8.4D1" not in c:
            errors.append("BL24: ADR-002 must reflect Phase C8.4D1")

    if adr003_path.exists():
        c = adr003_path.read_text(encoding="utf-8")
        if "C8.4D1" not in c:
            errors.append("BL24: ADR-003 must reflect Phase C8.4D1")

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
        if "public func processOutboundDiscover(" not in c:
            errors.append("BL26: iOS central connection must be governed by processOutboundDiscover")

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
    else:
        c = strip_comments(wire_link_info_ref_path.read_text(encoding="utf-8"))
        if "LINK_INFO_BYTES: int = 13" not in c or "PROTOCOL_VERSION: int = 0x02" not in c:
            errors.append("BL37: BleLinkInfo reference must define LINK_INFO_BYTES = 13 and PROTOCOL_VERSION = 0x02")
    if not wire_link_info_vec_path.exists():
        errors.append(f"BL37: BleLinkInfo test vectors missing at {wire_link_info_vec_path}")

    # ------------------------------------------------------------------------
    # BL38: Android BleGattServer onServiceAdded matching
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "service !== pendingService" not in c:
            errors.append("BL38: Android BleGattServer onServiceAdded must verify service === pendingService")

    # ------------------------------------------------------------------------
    # BL39: Android BleGattServer LinkInfo characteristic reference
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "linkInfoCharUuid: UUID = BleTransport.LINK_INFO_CHAR_UUID" not in c:
            errors.append("BL39: Android BleGattServer must reference BleTransport.LINK_INFO_CHAR_UUID")

    # ------------------------------------------------------------------------
    # BL40: iOS BleTransport LinkInfo characteristic reference
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)" not in c:
            errors.append("BL40: iOS BleTransport must define linkInfoCharacteristicUuid referencing FrameV2.linkInfoUuidString")

    # ------------------------------------------------------------------------
    # BL41: Android GattClient reads LinkInfo characteristic
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "readCharacteristic(linkInfo)" not in c:
            errors.append("BL41: Android GattClientConnection must read LinkInfo characteristic")

    # ------------------------------------------------------------------------
    # BL42: Android BleConnection state guard on bindRole
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if "s == BleConnectionState.LINK_INFO_WRITING || s == BleConnectionState.PROVISIONAL_CONNECTED" not in c:
            errors.append("BL42: Android BleConnection.bindRole must require state LINK_INFO_WRITING or PROVISIONAL_CONNECTED")

    # ------------------------------------------------------------------------
    # BL43: iOS BleConnection state guard on bindRole
    # ------------------------------------------------------------------------
    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if "state == .linkInfoWriting || state == .provisionalConnected" not in c:
            errors.append("BL43: iOS BleConnection.bindRole must require state linkInfoWriting or provisionalConnected")

    # ------------------------------------------------------------------------
    # BL44: Outbound transmission strictly forbidden before READY
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if "state != BleConnectionState.READY" not in c:
            errors.append("BL44: Android BleConnection.fragmentOutbound must require state == READY")

    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if "state != .ready" not in c:
            errors.append("BL44: iOS BleConnection.fragmentOutbound must require state == READY")

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
    # BL47: iOS BleTransport non-recursive snapshot caching
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "snapshotAuthority" not in c:
            errors.append("BL47: iOS BleTransport must integrate snapshotAuthority")

    # ------------------------------------------------------------------------
    # BL48: iOS BleTransport CCCD subscription tracking on callback
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "didUpdateNotificationStateFor ch: CBCharacteristic," not in c:
            errors.append("BL48: iOS BleTransport must track CCCD subscription on didUpdateNotificationStateFor callback")

    # ------------------------------------------------------------------------
    # BL49: Android GattClient typed operations and generation matching
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "gattGeneration" not in c or "g !== gatt" not in c or "BleTransport.LINK_INFO_CHAR_UUID" not in c:
            errors.append("BL49: Android GattClientConnection must use LINK_INFO UUID and generation verification")

    # ------------------------------------------------------------------------
    # BL50: Android LinkInfoSnapshotAuthority store-backed enumeration & saturating 255
    # ------------------------------------------------------------------------
    if android_snapshot_path.exists():
        c = strip_comments(android_snapshot_path.read_text(encoding="utf-8"))
        if "forEachHeldMsgId" not in c or "minOf(count, 255)" not in c:
            errors.append("BL50: Android LinkInfoSnapshotAuthority must enumerate forEachHeldMsgId and saturate at 255")

    # ------------------------------------------------------------------------
    # BL51: iOS LinkInfoSnapshotAuthority store-backed enumeration & saturating 255
    # ------------------------------------------------------------------------
    if ios_snapshot_path.exists():
        c = strip_comments(ios_snapshot_path.read_text(encoding="utf-8"))
        if "forEachHeldMsgId" not in c or "min(count, 255)" not in c:
            errors.append("BL51: iOS LinkInfoSnapshotAuthority must enumerate forEachHeldMsgId and saturate at 255")

    # ------------------------------------------------------------------------
    # BL52: Android BleTransport RSSI recording from scan observations
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "peerRssi[address] = result.rssi" not in c:
            errors.append("BL52: Android BleTransport must record observed RSSI from scan observations")
        if "rssi = 0" in c:
            errors.append("BL52: Android BleTransport must not synthesize fake rssi = 0")

    # ------------------------------------------------------------------------
    # BL53: Handshake transport readiness gated on subscription and role binding
    # ------------------------------------------------------------------------
    if android_conn_path.exists():
        c = strip_comments(android_conn_path.read_text(encoding="utf-8"))
        if "isRoleBound && isNotificationSubscribed" not in c:
            errors.append("BL53: Android BleConnection must gate isHandshakeTransportReady on isRoleBound and isNotificationSubscribed")

    if ios_conn_path.exists():
        c = strip_comments(ios_conn_path.read_text(encoding="utf-8"))
        if "_remoteNodeHint != nil && _localRole != nil && isNotificationSubscribed" not in c:
            errors.append("BL53: iOS BleConnection must gate isHandshakeTransportReady on isRoleBound and isNotificationSubscribed")

    # ------------------------------------------------------------------------
    # BL54: Connection capacity bounding (max active connections = 7)
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "MAX_ACTIVE_CONNECTIONS = 7" not in c:
            errors.append("BL54: Android BleTransport must bound inbound connections to MAX_ACTIVE_CONNECTIONS")

    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "maxActiveConnections = 7" not in c:
            errors.append("BL54: iOS BleTransport must bound inbound connections to maxActiveConnections")

    # ------------------------------------------------------------------------
    # BL55: iOS provisional lifecycle cleanup timer and didFailToConnect
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "didFailToConnect" not in c or "centralDriver?.getConnectionGeneration" not in c:
            errors.append("BL55: iOS BleTransport must implement didFailToConnect and centralDriver.getConnectionGeneration tracking")

    # ------------------------------------------------------------------------
    # BL56: Android BleGattServer generation tracking for registration and notifications
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "pendingServiceGeneration" not in c or "notificationGeneration" not in c:
            errors.append("BL56: Android BleGattServer must track pendingServiceGeneration and notificationGeneration")

    # ------------------------------------------------------------------------
    # BL57: iOS BleTransport backpressure checking canSendWriteWithoutResponse
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "canSendWriteWithoutResponse" not in c:
            errors.append("BL57: iOS BleTransport must check canSendWriteWithoutResponse for write-without-response")

    # ------------------------------------------------------------------------
    # BL58: Authoritative Peer Publication gated on physical duplex readiness
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "conn.isHandshakeTransportReady" not in c:
            errors.append("BL58: Android BleTransport must gate PeerEvent.Found on conn.isHandshakeTransportReady")

    # ------------------------------------------------------------------------
    # BL59: Snapshot caching without store traversal in ATT callbacks
    # ------------------------------------------------------------------------
    if android_snapshot_path.exists():
        c = strip_comments(android_snapshot_path.read_text(encoding="utf-8"))
        if "cachedBytes" not in c or "currentBytes()" not in c:
            errors.append("BL59: Android LinkInfoSnapshotAuthority must cache precomputed byte array")

    if ios_snapshot_path.exists():
        c = strip_comments(ios_snapshot_path.read_text(encoding="utf-8"))
        if "cachedData" not in c or "currentData()" not in c:
            errors.append("BL59: iOS LinkInfoSnapshotAuthority must cache precomputed Data")

    # ------------------------------------------------------------------------
    # BL60: Direct canonical JSON test vector consumption
    # ------------------------------------------------------------------------
    if android_test_substrate_path.exists():
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        if "wire/ble_link_info_vectors.json" not in c:
            errors.append("BL60: Android BleLinkSubstrateTest must directly consume wire/ble_link_info_vectors.json")

    if ios_test_substrate_path.exists():
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        if "wire/ble_link_info_vectors.json" not in c:
            errors.append("BL60: iOS BleLinkSubstrateTests must directly consume wire/ble_link_info_vectors.json")

    # ------------------------------------------------------------------------
    # BL61: iOS inbound central subscription authority
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "inboundPeripheralConnections[centralId]" not in c:
            errors.append("BL61: iOS didSubscribeTo must gate on active inbound connection in inboundPeripheralConnections")

    # ------------------------------------------------------------------------
    # BL62: Android BleServerOrchestrationDriver onNotificationSent signature
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if not re.search(r'fun\s+onNotificationSent\s*\(\s*deviceAddress:\s*String,\s*statusSuccess:\s*Boolean\s*\)', c):
            errors.append("BL62: Android onNotificationSent must take only (deviceAddress, statusSuccess)")
        if "notificationGen" in c or "expectedNotificationGen" in c:
            errors.append("BL62: Android onNotificationSent must not take synthetic notification generations")

    # ------------------------------------------------------------------------
    # BL63: Android BleServerOrchestrationDriver server epoch poisoning
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if "serverCallbackEpoch" not in c or "private var isPoisoned: Boolean = false" not in c or "PoisonServer" not in c:
            errors.append("BL63: Android BleServerOrchestrationDriver must implement server callback epoch poisoning")

    # ------------------------------------------------------------------------
    # BL64: Android BleServerOrchestrationDriver onServiceAdded matching
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if not re.search(r'fun\s+onServiceAdded\s*\(\s*epoch:\s*Long,\s*success:\s*Boolean\s*\)', c):
            errors.append("BL64: Android onServiceAdded must accept epoch and validate against serverCallbackEpoch")

    # ------------------------------------------------------------------------
    # BL65: Android BleGlobalCapacityAuthority
    # ------------------------------------------------------------------------
    if android_capacity_path.exists():
        c = strip_comments(android_capacity_path.read_text(encoding="utf-8"))
        if "maxTotalPeers: Int = 7" not in c or "tryAdmitOutbound" not in c or "tryAdmitInbound" not in c:
            errors.append("BL65: Android BleGlobalCapacityAuthority must bound total peers to 7 across outbound and inbound")

    # ------------------------------------------------------------------------
    # BL66: iOS BleGlobalCapacityAuthority
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "maxTotalPeers: Int = 7" not in c or "tryAdmitOutbound" not in c or "tryAdmitInbound" not in c:
            errors.append("BL66: iOS BleGlobalCapacityAuthority must bound total peers to 7 across outbound and inbound")

    # ------------------------------------------------------------------------
    # BL67: Android BleTransport instantiates centralDriver with snapshot authority & capacity
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "BleCentralOrchestrationDriver" not in c or "globalCapacity" not in c:
            errors.append("BL67: Android BleTransport must instantiate BleCentralOrchestrationDriver with global capacity")

    # ------------------------------------------------------------------------
    # BL68: Android BleGattServer receives BleServerOrchestrationDriver
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "orchestrationDriver: BleServerOrchestrationDriver" not in c:
            errors.append("BL68: Android BleGattServer must receive BleServerOrchestrationDriver")

    # ------------------------------------------------------------------------
    # BL69: iOS BleCentralOrchestrationDriver CoreBluetooth callbacks
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "public func onDiscover(" not in c or "public func onServicesDiscovered(" not in c or "public func onLinkInfoReadResult(" not in c:
            errors.append("BL69: iOS BleCentralOrchestrationDriver must support CoreBluetooth central callbacks")

    # ------------------------------------------------------------------------
    # BL70: iOS BlePeripheralOrchestrationDriver CoreBluetooth callbacks
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "public func onCentralRead(" not in c or "public func onCentralWrite(" not in c or "public func onCentralSubscribed(" not in c:
            errors.append("BL70: iOS BlePeripheralOrchestrationDriver must support CoreBluetooth peripheral callbacks")

    # ------------------------------------------------------------------------
    # BL71: iOS BleTransport instantiates centralDriver & peripheralDriver
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "centralDriver = BleCentralOrchestrationDriver" not in c or "peripheralDriver = BlePeripheralOrchestrationDriver" not in c:
            errors.append("BL71: iOS BleTransport must instantiate centralDriver and peripheralDriver")

    # ------------------------------------------------------------------------
    # BL72: iOS BleTransport delegates CoreBluetooth callbacks to drivers
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "public func processInboundWrite(" not in c or "public func processOutboundDiscover(" not in c:
            errors.append("BL72: iOS BleTransport must delegate CoreBluetooth callbacks to centralDriver and peripheralDriver")

    # ------------------------------------------------------------------------
    # BL73: Android LinkInfoSnapshotAuthority pure cache reads
    # ------------------------------------------------------------------------
    if android_snapshot_path.exists():
        c = strip_comments(android_snapshot_path.read_text(encoding="utf-8"))
        if "return cachedSnapshot.get()" not in c:
            errors.append("BL73: Android LinkInfoSnapshotAuthority currentSnapshot must be a pure cache read")
        if "return cachedBytes.get()" not in c:
            errors.append("BL73: Android LinkInfoSnapshotAuthority currentBytes must be a pure cache read")

    # ------------------------------------------------------------------------
    # BL74: iOS LinkInfoSnapshotAuthority pure cache reads
    # ------------------------------------------------------------------------
    if ios_snapshot_path.exists():
        c = strip_comments(ios_snapshot_path.read_text(encoding="utf-8"))
        if "public func currentSnapshot() -> BleLinkInfoV1? {" not in c or "lock.lock()" not in c or "return cachedSnapshot" not in c:
            errors.append("BL74: iOS LinkInfoSnapshotAuthority currentSnapshot must be a pure atomic cache read")

    # ------------------------------------------------------------------------
    # BL75: Android SqliteDeliveryRepository invokes onHeldSetMutated after commit
    # ------------------------------------------------------------------------
    if android_delivery_repo_path.exists():
        c = strip_comments(android_delivery_repo_path.read_text(encoding="utf-8"))
        if "onHeldSetMutated: (() -> Unit)?" not in c or "onHeldSetMutated?.invoke()" not in c:
            errors.append("BL75: Android SqliteDeliveryRepository must invoke onHeldSetMutated after retiring transaction commit")

    # ------------------------------------------------------------------------
    # BL76: Android MeshModule wires notifyHeldSetChanged to delivery repo
    # ------------------------------------------------------------------------
    if android_mesh_module_path.exists():
        c = strip_comments(android_mesh_module_path.read_text(encoding="utf-8"))
        if "store::notifyHeldSetChanged" not in c:
            errors.append("BL76: Android MeshModule must wire store::notifyHeldSetChanged into SqliteDeliveryRepository")

    # ------------------------------------------------------------------------
    # BL77: iOS MessageStore notifies held-set changed on retirement outside NSLock
    # ------------------------------------------------------------------------
    if ios_message_store_path.exists():
        c = strip_comments(ios_message_store_path.read_text(encoding="utf-8"))
        if "atomicAcknowledgeAndRetireWithFault" not in c or "notifyHeldSetChanged()" not in c:
            errors.append("BL77: iOS MessageStore must invoke notifyHeldSetChanged on retirement outside NSLock")

    # ------------------------------------------------------------------------
    # BL78: ADR-002 truthful status & CoreBluetooth background discovery note
    # ------------------------------------------------------------------------
    if adr002_path.exists():
        c = strip_comments(adr002_path.read_text(encoding="utf-8"))
        if "PHASE C8.4D1-R2 OPEN" not in c:
            errors.append("BL78: ADR-002 status must reflect PHASE C8.4D1-R2 OPEN")
        if "background discovery limitation" not in c.lower():
            errors.append("BL78: ADR-002 must document Apple CoreBluetooth Background Discovery Limitation")

    # ------------------------------------------------------------------------
    # BL79: ADR-003 truthful status
    # ------------------------------------------------------------------------
    if adr003_path.exists():
        c = strip_comments(adr003_path.read_text(encoding="utf-8"))
        if "C8.4D1-R2 Substrate Implementation & Closure:** OPEN" not in c:
            errors.append("BL79: ADR-003 status must reflect C8.4D1-R2 OPEN")

    # ------------------------------------------------------------------------
    # BL80: Substrate test inventories for R2.4
    # ------------------------------------------------------------------------
    if android_test_substrate_path.exists():
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        required_android = [
            "testNotification_N1Success",
            "testNotification_N1ExplicitFailure",
            "testNotification_N1TimeoutPoisonsServerEpoch",
            "testNotification_FreshServerEpochAllowsN2",
            "testNotification_LateOldCallbackCannotCompleteN2",
            "testNotification_StaleServiceAddedCannotMutateNewServer",
            "testLinkInfo_AckRetirementAutomaticallyRefreshesSnapshot",
            "testLinkInfo_ExpireRetirementAutomaticallyRefreshesSnapshot",
            "testLinkInfo_CancelRetirementAutomaticallyRefreshesSnapshot",
            "testLinkInfo_FailedRetirementDoesNotFalselyNotify",
            "testAttRead_CacheAbsent_FailsClosed_NoStoreTraversal",
            "testGlobalCapacity_MixedDirectionsFillAndReplace",
            "testServiceRegistration_StaleGeneration1Success_Ignored",
        ]
        for t in required_android:
            if t not in c:
                errors.append(f"BL80: Android test {t} missing in BleLinkSubstrateTest")

    if ios_test_substrate_path.exists():
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        required_ios = [
            "testLinkInfo_AckRetirementAutomaticallyRefreshesSnapshot",
            "testLinkInfo_ExpireRetirementAutomaticallyRefreshesSnapshot",
            "testLinkInfo_CancelRetirementAutomaticallyRefreshesSnapshot",
            "testLinkInfo_FailedRetirementDoesNotFalselyNotify",
            "testAttRead_CacheAbsent_FailsClosed_NoStoreTraversal",
            "testGlobalCapacity_MixedDirectionsFillAndReplace",
            "testDelegateCallback_InitiatorPhysicalDuplex_NoTransportReady",
            "testDelegateCallback_ResponderPhysicalDuplex_NoTransportReady",
            "testIosLinkInfoReadOnly_DoesNotConsumeCapacity",
            "testIosRejectedLinkInfoWrite_DoesNotConsumeCapacity",
            "testIosAcceptedWriteWithoutSubscription_TimesOutAndReleases",
            "testIosUnknownSubscription_DoesNotAllocate",
            "testIosProvisionalTimeout_ReleasesDriverCapacity",
            "testIosStaleProvisionalTimer_CannotReleaseReplacement",
            "testIosStop_ReleasesAllCapacity",
            "testIosStopStart_CanAdmitSevenFreshPeers",
        ]
        for t in required_ios:
            if t not in c:
                errors.append(f"BL80: iOS test {t} missing in BleLinkSubstrateTests")

    # ------------------------------------------------------------------------
    # BL81: Android UUID-only discovery scan authority
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "val optionalHint = metadata?.nodeHint" not in c or "val action = centralDriver.onScanResult(address, result.rssi, optionalHint)" not in c:
            errors.append("BL81: Android BleTransport must trigger centralDriver.onScanResult unconditionally for UUID-only scan results")

    # ------------------------------------------------------------------------
    # BL82: Android Server physical link direction isolation
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "isRoleBoundPredicate = { peerAddress -> serverDriver.getInboundConnection(peerAddress)?.isRoleBound == true }" not in c:
            errors.append("BL82: Android BleTransport isRoleBoundPredicate must check only serverDriver inbound connection")
        if "handleCentralInboundNotification" not in c or "handleServerInboundWrite" not in c:
            errors.append("BL82: Android BleTransport must separate central and server inbound traffic handlers")

    # ------------------------------------------------------------------------
    # BL83: Android Inbound Responder metadata propagation
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "responderRemoteLinkInfo[peerAddress] = decoded" not in c:
            errors.append("BL83: Android BleTransport handleIncomingLinkInfoWrite must store decoded BleLinkInfoV1")

    # ------------------------------------------------------------------------
    # ------------------------------------------------------------------------
    # BL84: iOS Non-allocating LinkInfo read
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "public func onCentralRead(centralId: UUID) -> BlePeripheralAction {" not in c:
            errors.append("BL84: iOS BlePeripheralOrchestrationDriver onCentralRead must be implemented")
        read_fn_start = c.find("public func onCentralRead(centralId: UUID) -> BlePeripheralAction {")
        if read_fn_start != -1:
            write_fn_start = c.find("public func onCentralWrite(", read_fn_start)
            body = c[read_fn_start:write_fn_start] if write_fn_start != -1 else c[read_fn_start:]
            if "tryAdmitInbound" in body or "ensureAdmitted" in body or "admittedCentrals.insert" in body or "admit" in body.lower():
                errors.append("BL84: iOS BlePeripheralOrchestrationDriver onCentralRead must be completely stateless and non-allocating")

    # ------------------------------------------------------------------------
    # BL85: iOS Inbound pre-subscription timer and timeout
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "onInboundTimeout(centralId:" not in c:
            errors.append("BL85: iOS BleTransport must manage inbound pre-subscription timeout")

    # ------------------------------------------------------------------------
    # BL86: Real Android server callback factory
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "fun makeServerCallback(callbackEpoch: Long): BluetoothGattServerCallback" not in c or "val currentCallback = makeServerCallback(gen)" not in c:
            errors.append("BL86: Android BleGattServer must instantiate a new BluetoothGattServerCallback per server epoch")

    # ------------------------------------------------------------------------
    # BL87: Thread-safe capacity authority leases
    # ------------------------------------------------------------------------
    if android_capacity_path.exists():
        c = strip_comments(android_capacity_path.read_text(encoding="utf-8"))
        if "data class CapacityLease(" not in c or "enum class BleDirection" not in c or "synchronized" not in c:
            errors.append("BL87: Android BleGlobalCapacityAuthority must use synchronized CapacityLease tokens")

    # ------------------------------------------------------------------------
    # BL88: iOS duplicate/conflicting LinkInfo write handling without state crash
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "admittedCentrals.contains(centralId)" not in c or "conn.isRoleBound || conn.state == .ready" not in c:
            errors.append("BL88: iOS BlePeripheralOrchestrationDriver must check for active admitted roleBound connections on central write")
        if "Conflicting LinkInfo write on active relation" not in c:
            errors.append("BL88: iOS BlePeripheralOrchestrationDriver must reject conflicting LinkInfo writes on active relations")

    # ------------------------------------------------------------------------
    # BL89: Exact CapacityLease ownership and leaseId matching
    # ------------------------------------------------------------------------
    if android_capacity_path.exists():
        c = strip_comments(android_capacity_path.read_text(encoding="utf-8"))
        if "val leaseId: Long" not in c or "current.leaseId == lease.leaseId" not in c:
            errors.append("BL89: Android BleGlobalCapacityAuthority must validate exact leaseId matching on release")

    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "let leaseId: UInt64" not in c or "current.leaseId == lease.leaseId" not in c:
            errors.append("BL89: iOS BleGlobalCapacityAuthority must validate exact leaseId matching on release")

    # ------------------------------------------------------------------------
    # BL90: Direction-scoped publication via RelationKey
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "ConcurrentHashMap.newKeySet<RelationKey>()" not in c:
            errors.append("BL90: Android BleTransport must use publishedRelations and emit Lost only when 0 relations remain")

    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "Set<RelationKey> = []" not in c:
            errors.append("BL90: iOS BleTransport must track publishedRelations and emit disconnect only when 0 relations remain")

    # ------------------------------------------------------------------------
    # BL91: Android GattClient.kt callback authority & currentOp verification
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "op.opType == GattOpType.SERVICE_DISCOVERY" not in c or "op.opType == GattOpType.LINK_INFO_READ" not in c or "op.opType == GattOpType.CCCD_WRITE" not in c:
            errors.append("BL91: Android GattClientConnection must strictly match PendingGattOp in callbacks")

    # ------------------------------------------------------------------------
    # BL92: Immutable BleElectionContext bound on authoritative LinkInfo read
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if "data class BleElectionContext(" not in c or "electionContexts[peerAddress] = BleElectionContext" not in c:
            errors.append("BL92: Android BleCentralOrchestrationDriver must record immutable BleElectionContext")

    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "struct BleElectionContext" not in c or "electionContexts[peerId] = BleElectionContext" not in c:
            errors.append("BL92: iOS BleCentralOrchestrationDriver must record immutable BleElectionContext")

    # ------------------------------------------------------------------------
    # BL93: Android GattClientConnection clientToken and generation-scoped disconnect
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "val clientToken: Long = nextClientToken()" not in c or "onDisconnected(clientToken, gen)" not in c:
            errors.append("BL93: Android GattClientConnection must produce clientToken and forward on disconnect")

    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "activeClient.clientToken != clientToken" not in c:
            errors.append("BL93: Android BleTransport must ignore stale disconnects from replaced clients")

    # ------------------------------------------------------------------------
    # BL94: Android BleGattServer.kt LinkInfo rejection teardown
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "is BleServerAction.RejectWrite" not in c or "s?.cancelConnection(device)" not in c:
            errors.append("BL94: Android BleGattServer must cancel physical connection on RejectWrite")

    # ------------------------------------------------------------------------
    # BL95: R2.6 Substrate test inventories
    # ------------------------------------------------------------------------
    if android_test_substrate_path.exists():
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        required_r26_android = [
            "testAndroidCapacity_Gen1Admitted_Gen2Replacement_StaleGen1ReleaseDoesNotReleaseGen2",
            "testAndroidCapacity_DriverOwnsExactLease_StaleDisconnectDoesNotReleaseReplacement",
            "testAndroidServer_MalformedLinkInfo_ReleasesCapacity",
            "testAndroidServer_TieLinkInfo_ReleasesCapacity",
            "testAndroidServer_CentralRoleElection_ReleasesCapacity",
            "testAndroidServer_InboundTimeout_ReleasesCapacity",
            "testAndroidServer_SevenRejectedPeersCannotExhaustFutureAdmissions",
            "testAndroidCrossing_CentralDuplexReady_WrongServerDirectionTeardown_NoLost",
            "testAndroidElectionContext_ImmutableAcrossStaleReads",
        ]
        for t in required_r26_android:
            if t not in c:
                errors.append(f"BL95: Android test {t} missing in BleLinkSubstrateTest")

    if ios_test_substrate_path.exists():
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        required_r26_ios = [
            "testIosCapacity_StaleOutboundReleaseCannotReleaseReplacement",
            "testIosCapacity_StaleInboundReleaseCannotReleaseReplacement",
            "testIosCapacity_DuplicateReleaseIsIdempotent",
            "testIosCapacity_MixedDirectionsNeverExceedsSeven",
            "testIosCapacity_StopResetLeavesZeroLeases",
            "testIosLinkInfo_FirstValidWrite_BindsResponder",
            "testIosLinkInfo_ExactDuplicate_NoCrashNoRebindNoExtraLease",
            "testIosLinkInfo_ConflictingDuplicate_RejectedNoCrash",
            "testIosLinkInfo_DuplicateAfterSubscription_DoesNotResetRelation",
            "testIosLinkInfo_DuplicateCannotRestartTimeoutForDifferentGeneration",
            "testIosAdapter_DirectReducerMapping",
        ]
        for t in required_r26_ios:
            if t not in c:
                errors.append(f"BL95: iOS test {t} missing in BleLinkSubstrateTests")

    # ------------------------------------------------------------------------
    # BL96: Android server terminal callback generation matching
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if not re.search(r'fun\s+onClientDisconnected\s*\(\s*deviceAddress:\s*String,\s*expectedGen:\s*Long\s*=\s*0L\s*\)', c):
            errors.append("BL96: Android BleServerOrchestrationDriver onClientDisconnected must take expectedGen")

    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "orchestrationDriver?.onClientDisconnected(address)" not in c:
            errors.append("BL96: Android BleGattServer onConnectionStateChange must forward disconnect to orchestrationDriver")

    # ------------------------------------------------------------------------
    # BL97: Android inbound timeout scheduled on admission
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "handleInboundClientAdmitted" not in c or "inboundJobs[peerAddress] = job" not in c or "handleInboundTimeout" not in c:
            errors.append("BL97: Android BleTransport must schedule inbound timeout on admission")

    # ------------------------------------------------------------------------
    # BL98: Android pure centralized publication reducer
    # ------------------------------------------------------------------------
    if android_transport_path.exists():
        c = strip_comments(android_transport_path.read_text(encoding="utf-8"))
        if "fun publishRelation(key: RelationKey" not in c or "fun unpublishRelation(key: RelationKey" not in c:
            errors.append("BL98: Android BleTransport must implement publishRelation and unpublishRelation reducers")
        if "publicationLock" not in c:
            errors.append("BL98: Android BleTransport publication reducers must be synchronized under publicationLock")

    # ------------------------------------------------------------------------
    # BL99: Android BleServerOrchestrationDriver full canonical LinkInfo equality
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if "isExactDuplicate = (existing == remoteInfo)" not in c:
            errors.append("BL99: Android BleServerOrchestrationDriver onLinkInfoWriteRequest must check full canonical BleLinkInfoV1 equality")

    # ------------------------------------------------------------------------
    # BL100: iOS full canonical LinkInfo equality on duplicate write
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "acceptedRemoteLinkInfo[centralId], existing == remoteInfo" not in c:
            errors.append("BL100: iOS BlePeripheralOrchestrationDriver onCentralWrite must check full canonical BleLinkInfoV1 equality")

    # ------------------------------------------------------------------------
    # BL101: iOS single generation authority
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "public func getCentralGeneration(_ centralId: UUID) -> UInt64" not in c:
            errors.append("BL101: iOS BlePeripheralOrchestrationDriver must expose getCentralGeneration")

    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "driver.getCentralGeneration(" not in c:
            errors.append("BL101: iOS BleTransport must retrieve central generation from peripheralDriver authority")

    # ------------------------------------------------------------------------
    # BL102: iOS generation-safe terminal callbacks
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "public func onCentralUnsubscribed(centralId: UUID, expectedGen: UInt64 = 0)" not in c:
            errors.append("BL102: iOS BlePeripheralOrchestrationDriver onCentralUnsubscribed must take expectedGen")
        if "public func onDisconnected(peerId: UUID, expectedGen: UInt64 = 0)" not in c:
            errors.append("BL102: iOS BleCentralOrchestrationDriver onDisconnected must take expectedGen")

    # ------------------------------------------------------------------------
    # BL103: iOS pure publication reducer
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "public func publishRelation(_ key: RelationKey" not in c or "public func unpublishRelation(_ key: RelationKey" not in c:
            errors.append("BL103: iOS BleTransport must implement pure publishRelation and unpublishRelation reducers")

    # ------------------------------------------------------------------------
    # BL104: iOS production extracted reducers
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        required_ios_reducers = [
            "public func processInboundWrite(",
            "public func processInboundSubscribe(",
            "public func processInboundUnsubscribe(",
            "public func processOutboundDisconnect(",
            "public func handleOutboundTimeout(",
            "public func handleInboundTimeout("
        ]
        for r in required_ios_reducers:
            if r not in c:
                errors.append(f"BL104: iOS BleTransport must implement production reducer {r}")

    # ------------------------------------------------------------------------
    # BL105: Android GattClient.kt callback matching controls
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "op.gattGeneration == gen" not in c:
            errors.append("BL105: Android GattClientConnection must verify currentOp generation matching")

    # ------------------------------------------------------------------------
    # BL106: Section N regression test inventory (Android)
    # ------------------------------------------------------------------------
    if android_test_substrate_path.exists():
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        required_r27_android = [
            "testTransportInboundAdmission_SchedulesExactGenerationTimeout",
            "testTransportInboundTimeout_ReleasesExactRelation",
            "testTransportPublication_UnpublishedDisconnectEmitsNoLost",
            "testTransportPublication_CentralDisconnectEmitsExactlyOneLost",
            "testTransportPublication_ServerDisconnectEmitsExactlyOneLost",
            "testTransportPublication_CrossingOneDiesNoLost",
            "testTransportPublication_FinalRelationDiesExactlyOneLost",
            "testTransportPublication_StaleGenerationRemovalNoOp",
            "testServerDisconnect_StaleGenerationCannotDeleteReplacement",
            "testGattClient_UnmatchedReadNotForwarded",
            "testGattClient_UnmatchedCccdNotForwarded",
            "testServerLinkInfo_SameHintDifferentFlagsRejected",
            "testServerLinkInfo_SameHintDifferentDigestRejected",
        ]
        for t in required_r27_android:
            if t not in c:
                errors.append(f"BL106: Android test {t} missing in BleLinkSubstrateTest")

    # ------------------------------------------------------------------------
    # BL107: Section N regression test inventory (iOS)
    # ------------------------------------------------------------------------
    if ios_test_substrate_path.exists():
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        required_r27_ios = [
            "testIosLinkInfo_SameHintDifferentFlagsRejected",
            "testIosLinkInfo_SameHintDifferentDigestRejected",
            "testIosLinkInfo_SameHintDifferentQueueDepthRejected",
            "testIosTransport_DuplicateDoesNotRestartInboundTimer",
            "testIosTransport_DuplicateTimeoutReleasesDriverLeaseAndTransportState",
            "testIosTransport_PostTimeoutNewWriteCreatesCleanNextGeneration",
            "testIosTransport_DuplicateSequenceCannotCrashClosedConnection",
            "testIosTransport_StaleOutboundDisconnectCannotDeleteReplacement",
            "testIosTransport_StaleInboundTerminalCannotDeleteReplacement",
            "testIosProductionWriteReducer_CoversTimerAndPublicationSideEffects",
        ]
        for t in required_r27_ios:
            if t not in c:
                errors.append(f"BL107: iOS test {t} missing in BleLinkSubstrateTests")

    # ------------------------------------------------------------------------
    # BL108: Android ServerPeerSlot and ServerPeerSlotState
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if "enum class ServerPeerSlotState" not in c or "data class ServerPeerSlot(" not in c:
            errors.append("BL108: Android BleOrchestrationDriver must define ServerPeerSlot and ServerPeerSlotState")
        if "ServerPeerSlotState.IDLE" not in c or "ServerPeerSlotState.ACTIVE" not in c or "ServerPeerSlotState.CLOSING" not in c:
            errors.append("BL108: Android ServerPeerSlotState must define IDLE, ACTIVE, and CLOSING states")

    # ------------------------------------------------------------------------
    # BL109: Android OutboundPeerSlot and OutboundPeerSlotState
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if "enum class OutboundPeerSlotState" not in c or "data class OutboundPeerSlot(" not in c:
            errors.append("BL109: Android BleOrchestrationDriver must define OutboundPeerSlot and OutboundPeerSlotState")

    # ------------------------------------------------------------------------
    # BL110: Android GattLifetimeToken and no BluetoothGatt::class.java.cast(null)
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "data class GattLifetimeToken(" not in c:
            errors.append("BL110: Android GattClientConnection must define GattLifetimeToken")
        if "BluetoothGatt::class.java.cast(null)" in c:
            errors.append("BL110: Android GattClientConnection must NOT contain BluetoothGatt::class.java.cast(null)")

    # ------------------------------------------------------------------------
    # BL111: Android BleServerAction.AcceptDuplicateWrite
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if "data class AcceptDuplicateWrite(" not in c:
            errors.append("BL111: Android BleServerAction must define AcceptDuplicateWrite")

    # ------------------------------------------------------------------------
    # BL112: iOS OutboundPeerSlot and OutboundSlotState
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "enum OutboundSlotState" not in c or "struct OutboundPeerSlot" not in c:
            errors.append("BL112: iOS BleOrchestrationDriver must define OutboundPeerSlot and OutboundSlotState")

    # ------------------------------------------------------------------------
    # BL113: iOS InboundPeerSlot and InboundSlotState
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "enum InboundSlotState" not in c or "struct InboundPeerSlot" not in c:
            errors.append("BL113: iOS BleOrchestrationDriver must define InboundPeerSlot and InboundSlotState")

    # ------------------------------------------------------------------------
    # BL114: iOS BlePeripheralAction.acceptDuplicateWrite
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "case acceptDuplicateWrite(UUID, Data)" not in c:
            errors.append("BL114: iOS BlePeripheralAction must define acceptDuplicateWrite")

    # ------------------------------------------------------------------------
    # BL115: Section 8 & 9 regression test inventory (Android)
    # ------------------------------------------------------------------------
    if android_test_substrate_path.exists():
        c = strip_comments(android_test_substrate_path.read_text(encoding="utf-8"))
        required_r28_android = [
            "testServerLifecycle_ConnectedWhileActiveDoesNotRenumberRelation",
            "testServerLifecycle_ConnectedWhileClosingCannotAdmitReplacement",
            "testServerLifecycle_ClosingDisconnectRetiresExactGeneration",
            "testServerLifecycle_ReconnectOnlyAfterOldDisconnectGetsNextGeneration",
            "testServerLifecycle_DuplicateDisconnectAfterReplacementIsNoOp",
            "testServerLifecycle_LeaseGenerationAlwaysEqualsRelationGeneration",
            "testServerLifecycle_ConnectionGenerationAlwaysEqualsRelationGeneration",
            "testServerLifecycle_InboundTimerGenerationAlwaysEqualsRelationGeneration",
            "testGattClient_OldGattLifetimeNotForwarded",
            "testGattClient_OldGattDisconnectCannotDeleteReplacement",
            "testGattClient_MatchedReadForwardsExactlyOnce",
            "testGattClient_MatchedWriteForwardsExactlyOnce",
            "testServerLinkInfo_ExactDuplicate_NoCrashNoRebindNoExtraLease",
        ]
        for t in required_r28_android:
            if t not in c:
                errors.append(f"BL115: Android test {t} missing in BleLinkSubstrateTest")

    # ------------------------------------------------------------------------
    # BL116: Section 15, 16, 17 regression test inventory (iOS)
    # ------------------------------------------------------------------------
    if ios_test_substrate_path.exists():
        c = strip_comments(ios_test_substrate_path.read_text(encoding="utf-8"))
        required_r28_ios = [
            "testIosDuplicateBeforeSubscription_ReusesOriginalTimer",
            "testIosDuplicateAfterSubscription_DoesNotCreateTimer",
            "testIosPhysicalReadyTimeoutCallback_LeavesNoTimerEntry",
            "testIosDuplicateAfterSubscription_DoesNotChangeRelationGeneration",
            "testIosDuplicateAfterSubscription_DoesNotChangeLease",
            "testIosOutboundAdapter_ClosingBlocksSamePeerReplacement",
            "testIosOutboundAdapter_OldDisconnectCannotDeleteReplacement",
            "testIosOutboundAdapter_OldServiceCallbackCannotAdvanceReplacement",
            "testIosOutboundAdapter_OldLinkInfoCallbackCannotAdvanceReplacement",
            "testIosOutboundAdapter_OldNotifyCallbackCannotPublishReplacement",
            "testIosInboundAdapter_OldUnsubscribeCannotDeleteReplacement",
            "testIosInboundAdapter_PreviousManagerEpochCannotDeletePostRestartRelation",
            "testIosInboundAdapter_DuplicateAfterSubscribedCreatesNoTimer",
            "testIosPublicationEdgeReducer_EventCountMatrix",
        ]
        for t in required_r28_ios:
            if t not in c:
                errors.append(f"BL116: iOS test {t} missing in BleLinkSubstrateTests")

    # ------------------------------------------------------------------------
    # BL117: Android ServerPeerSlotState includes QUARANTINED
    # ------------------------------------------------------------------------
    if android_driver_path.exists():
        c = strip_comments(android_driver_path.read_text(encoding="utf-8"))
        if not re.search(r'enum\s+class\s+ServerPeerSlotState\s*\{[^}]*\bQUARANTINED\b', c, re.DOTALL):
            errors.append("BL117: Android ServerPeerSlotState must include QUARANTINED state")

    # ------------------------------------------------------------------------
    # BL118: Android GattServer processConnectionStateChange
    # ------------------------------------------------------------------------
    if android_server_path.exists():
        c = strip_comments(android_server_path.read_text(encoding="utf-8"))
        if "fun processConnectionStateChange(" not in c or "orchestrationDriver?.onClientDisconnected(address)" not in c:
            errors.append("BL118: Android GattServer must define processConnectionStateChange delegating to orchestrationDriver without synthetic expectedGen")

    # ------------------------------------------------------------------------
    # BL119: Android GattClient token-bound callbacks
    # ------------------------------------------------------------------------
    if android_client_path.exists():
        c = strip_comments(android_client_path.read_text(encoding="utf-8"))
        if "fun makeGattCallback(token: GattLifetimeToken)" not in c:
            errors.append("BL119: Android GattClientConnection must define makeGattCallback(token: GattLifetimeToken)")

    # ------------------------------------------------------------------------
    # BL120: iOS RelationPeripheralDelegate
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "class RelationPeripheralDelegate: NSObject, CBPeripheralDelegate" not in c:
            errors.append("BL120: iOS BleTransport must define RelationPeripheralDelegate: NSObject, CBPeripheralDelegate")

    # ------------------------------------------------------------------------
    # BL121: iOS OutboundPhysicalLifetime & InboundSubscriptionLifetime
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if not re.search(r'\bstruct\s+OutboundPhysicalLifetime\b', c) or not re.search(r'\bstruct\s+InboundSubscriptionLifetime\b', c):
            errors.append("BL121: iOS BleTransport must define OutboundPhysicalLifetime and InboundSubscriptionLifetime")

    # ------------------------------------------------------------------------
    # BL122: iOS BleTransport currentTransportEpoch
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "var currentTransportEpoch: UInt64" not in c or "currentTransportEpoch += 1" not in c:
            errors.append("BL122: iOS BleTransport must track currentTransportEpoch and advance on start/stop")

    # ------------------------------------------------------------------------
    # BL123: iOS acceptDuplicateWrite maps to .success in didReceiveWrite
    # ------------------------------------------------------------------------
    if ios_transport_path.exists():
        c = strip_comments(ios_transport_path.read_text(encoding="utf-8"))
        if "case .acceptWrite, .acceptDuplicateWrite, .acceptWriteAndDuplexReady:" not in c and "case .acceptWrite, .acceptWriteAndDuplexReady, .acceptDuplicateWrite:" not in c:
            errors.append("BL123: iOS BleTransport.peripheralManager(_:didReceiveWrite:) must include .acceptDuplicateWrite in success response")

    # ------------------------------------------------------------------------
    # BL124: iOS BleOrchestrationDriver active slot generation state
    # ------------------------------------------------------------------------
    if ios_driver_path.exists():
        c = strip_comments(ios_driver_path.read_text(encoding="utf-8"))
        if "case active(UInt64)" not in c:
            errors.append("BL124: iOS OutboundSlotState and InboundSlotState must define case active(UInt64)")

    return errors


def run_selftest() -> int:
    """Mutation testing for all BL01-BL124 control rules."""
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
        ("ios_transport", "peripheral?.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj])", "/* peripheral?.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj]) */", "BL11"),
        ("android_transport", "val roleCoordinator = BleRoleBindingCoordinator", "val roleCoordinatorMutated = BleRoleBindingCoordinator", "BL12"),
        ("ios_transport", "public var roleCoordinator: BleRoleBindingCoordinator?", "public var roleCoordinatorMutated: BleRoleBindingCoordinator?", "BL13"),
        ("android_transport", "conn?.markDisconnected()", "/* conn?.markDisconnected() */", "BL14"),
        ("ios_transport", "outboundCentralConnections.removeAll()", "/* outboundCentralConnections.removeAll() */", "BL15"),
        ("android_transport", "MAX_DISCOVERED_PEERS = 64", "MAX_DISCOVERED_PEERS = 9999", "BL16"),
        ("ios_transport", "maxDiscoveredPeers = 64", "maxDiscoveredPeers = 9999", "BL17"),
        ("android_transport", "val serverStarted = gattServer.start()", "startAdvertising()\n        val serverStarted = gattServer.start()", "BL18"),
        ("ios_transport", "[BleTransport.serviceUuid]", "[BleTransport.serviceUuid],\n            CBAdvertisementDataLocalNameKey: \"GS\"", "BL19"),
        ("android_test_substrate", "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator", "disabled_testRoleElection", "BL20"),
        ("ios_test_substrate", "testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator", "disabled_testRoleElection", "BL21"),
        ("android_transport", "sessions?.seal(peerId, bytes)", "sessions?.beginInitiator(peerId, bytes)", "BL22"),
        ("ios_transport", "sessions?.seal(peerId, frame.encode())", "sessions?.beginInitiator(peerId, frame.encode())", "BL22"),
        ("android_mesh_node", "const val LINK_LAYER_READY = false", "const val LINK_LAYER_READY = true", "BL23"),
        ("ios_mesh_node", "public static let linkLayerReady = false", "public static let linkLayerReady = true", "BL23"),
        ("ios_app_container", "import Foundation", "import Foundation\nimport GodstoneMesh", "BL23"),
        ("adr002", "C8.4D1", "XXX_REMOVED", "BL24"),
        ("adr003", "C8.4D1", "XXX_REMOVED", "BL24"),
        ("android_transport", "activeClientConnections[address] = client", "/* activeClientConnections[address] = client */", "BL25"),
        ("ios_transport", "public func processOutboundDiscover(", "public func processOutboundDiscoverMutated(", "BL26"),
        ("android_transport", "if (!serverStarted)", "if (false)", "BL27"),
        ("android_server", "if (subscribedDevices[deviceAddress] != true)", "if (false)", "BL28"),
        ("android_transport", "conn.maxAttValueLength = maxAttLen", "/* conn.maxAttValueLength = maxAttLen */", "BL29"),
        ("ios_transport", "maxQueuedAttValues = 16", "maxQueuedAttValues = 999999", "BL30"),
        ("android_wirev2", 'val LINK_INFO_UUID: java.util.UUID = java.util.UUID.fromString("6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10")', "/* removed LINK_INFO_UUID */", "BL31"),
        ("ios_wirev2", 'public static let linkInfoUuidString = "6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10"', "/* removed linkInfoUuidString */", "BL31"),
        ("android_transport", "val LINK_INFO_CHAR_UUID: UUID = FrameV2.LINK_INFO_UUID", "val LINK_INFO_CHAR_UUID: UUID = UUID.fromString(\"6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10\")", "BL32"),
        ("ios_transport", "public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)", "public static let linkInfoCharacteristicUuid = CBUUID(string: \"6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10\")", "BL32"),
        ("android_record_codec", "CLOSE(0x21.toByte());", "CLOSE(0x21.toByte()),\n    LINK_INFO(0x22.toByte());", "BL33"),
        ("ios_record_codec", "case close = 0x21", "case close = 0x21\n    case linkInfo = 0x22", "BL33"),
        ("android_conn", "PROVISIONAL_CONNECTING,", "/* PROVISIONAL_CONNECTING, */", "BL34"),
        ("ios_conn", "case provisionalConnecting", "/* case provisionalConnecting */", "BL34"),
        ("android_role", "data class BleLinkInfoV1(", "data class BleLinkInfoV1Mutated(", "BL35"),
        ("ios_role", "struct BleLinkInfoV1: Equatable", "struct BleLinkInfoV1Mutated: Equatable", "BL35"),
        ("android_coord", "class BleRoleBindingCoordinator(", "class BleRoleBindingCoordinatorMutated(", "BL36"),
        ("ios_coord", "public final class BleRoleBindingCoordinator:", "public final class BleRoleBindingCoordinatorMutated:", "BL36"),
        ("wire_link_info_ref", "LINK_INFO_BYTES: int = 13", "/* LINK_INFO_BYTES_MUTATED */", "BL37"),
        ("android_server", "service !== pendingService", "false", "BL38"),
        ("android_server", "val linkInfoCharUuid: UUID = BleTransport.LINK_INFO_CHAR_UUID", "val linkInfoCharUuidMutated: UUID = BleTransport.LINK_INFO_CHAR_UUID", "BL39"),
        ("ios_transport", "public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)", "public static let linkInfoCharacteristicUuidMutated = CBUUID(string: FrameV2.linkInfoUuidString)", "BL40"),
        ("android_client", "readCharacteristic(linkInfo)", "readCharacteristic(null)", "BL41"),
        ("android_conn", "s == BleConnectionState.LINK_INFO_WRITING || s == BleConnectionState.PROVISIONAL_CONNECTED", "true", "BL42"),
        ("ios_conn", "state == .linkInfoWriting || state == .provisionalConnected", "true", "BL43"),
        ("android_conn", "state != BleConnectionState.READY", "state != BleConnectionState.CLOSED", "BL44"),
        ("ios_conn", "state != .ready", "state != .closed", "BL44"),
        ("ios_transport", "var outboundCentralConnections: [UUID: BleConnection] = [:]", "var outboundCentralConnectionsMutated: [UUID: BleConnection] = [:]", "BL45"),
        ("android_transport", "snapshotAuthority", "/* snapshotAuthority */ identity.nodeHint.copyOf(6)", "BL46"),
        ("ios_transport", "snapshotAuthority", "/* snapshotAuthority */", "BL47"),
        ("ios_transport", "didUpdateNotificationStateFor ch: CBCharacteristic,", "didUpdateNotificationStateForMutated ch: CBCharacteristic,", "BL48"),
        ("android_client", "BleTransport.LINK_INFO_CHAR_UUID", "UUID.randomUUID()", "BL49"),
        ("android_snapshot", "minOf(count, 255)", "count", "BL50"),
        ("ios_snapshot", "min(count, 255)", "count", "BL51"),
        ("android_transport", "peerRssi[address] = result.rssi", "peerRssi[address] = 0\n rssi = 0", "BL52"),
        ("android_conn", "isRoleBound && isNotificationSubscribed", "isRoleBound", "BL53"),
        ("ios_conn", "_remoteNodeHint != nil && _localRole != nil && isNotificationSubscribed", "_remoteNodeHint != nil && _localRole != nil", "BL53"),
        ("android_transport", "MAX_ACTIVE_CONNECTIONS = 7", "MAX_ACTIVE_CONNECTIONS = 9999", "BL54"),
        ("ios_transport", "maxActiveConnections = 7", "maxActiveConnections = 9999", "BL54"),
        ("ios_transport", "centralDriver?.getConnectionGeneration", "/* centralDriver?.getConnectionGeneration */", "BL55"),
        ("android_server", "pendingServiceGeneration", "/* pendingServiceGeneration */", "BL56"),
        ("ios_transport", "p.canSendWriteWithoutResponse", "true", "BL57"),
        ("android_transport", "conn.isHandshakeTransportReady", "true", "BL58"),
        ("android_snapshot", "cachedBytes", "/* cachedBytes */", "BL59"),
        ("ios_snapshot", "cachedData", "/* cachedData */", "BL59"),
        ("android_test_substrate", "wire/ble_link_info_vectors.json", "wire/hardcoded_copy.json", "BL60"),
        ("ios_test_substrate", "wire/ble_link_info_vectors.json", "wire/hardcoded_copy.json", "BL60"),
        ("ios_transport", "inboundPeripheralConnections[centralId]", "/* inboundPeripheralConnections[centralId] */", "BL61"),
        ("android_driver", "fun onNotificationSent(\n        deviceAddress: String,\n        statusSuccess: Boolean\n    )", "fun onNotificationSent(\n        deviceAddress: String,\n        statusSuccess: Boolean,\n        notificationGen: Long\n    )", "BL62"),
        ("android_driver", "private var isPoisoned: Boolean = false", "/* removed isPoisoned */", "BL63"),
        ("android_driver", "epoch: Long, success: Boolean", "epoch: Long, success: Boolean, mutated: Boolean = true", "BL64"),
        ("android_capacity", "val maxTotalPeers: Int = 7", "val maxTotalPeers: Int = 99", "BL65"),
        ("ios_driver", "maxTotalPeers: Int = 7", "maxTotalPeers: Int = 99", "BL66"),
        ("android_transport", "BleCentralOrchestrationDriver(", "/* BleCentralOrchestrationDriver( */", "BL67"),
        ("android_server", "private val orchestrationDriver: BleServerOrchestrationDriver? = null", "/* private val orchestrationDriver */", "BL68"),
        ("ios_driver", "public func onDiscover(", "public func onDiscoverMutated(", "BL69"),
        ("ios_driver", "public func onCentralRead(", "public func onCentralReadMutated(", "BL70"),
        ("ios_transport", "centralDriver = BleCentralOrchestrationDriver(", "/* centralDriver = BleCentralOrchestrationDriver( */", "BL71"),
        ("ios_transport", "public func processInboundWrite(", "public func processInboundWriteMutated(", "BL72"),
        ("android_snapshot", "return cachedSnapshot.get()", "/* return cachedSnapshot.get() */ return refresh()", "BL73"),
        ("ios_snapshot", "return cachedSnapshot", "/* return cachedSnapshot */ return refresh()", "BL74"),
        ("android_delivery_repo", "onHeldSetMutated?.invoke()", "/* onHeldSetMutated?.invoke() */", "BL75"),
        ("android_mesh_module", "store::notifyHeldSetChanged", "null", "BL76"),
        ("ios_message_store", "notifyHeldSetChanged()", "/* notifyHeldSetChanged() */", "BL77"),
        ("adr002", "PHASE C8.4D1-R2 OPEN", "PHASE C8.4D1-R2 CLOSED", "BL78"),
        ("adr003", "C8.4D1-R2 Substrate Implementation & Closure:** OPEN", "C8.4D1-R2 Substrate Implementation & Closure:** CLOSED", "BL79"),
        ("android_test_substrate", "testNotification_N1TimeoutPoisonsServerEpoch", "disabled_testNotification", "BL80"),
        ("ios_test_substrate", "testDelegateCallback_InitiatorPhysicalDuplex_NoTransportReady", "disabled_testDelegateCallback", "BL80"),
        ("android_transport", "val optionalHint = metadata?.nodeHint", "/* val optionalHint = metadata?.nodeHint */", "BL81"),
        ("android_transport", "isRoleBoundPredicate = { peerAddress -> serverDriver.getInboundConnection(peerAddress)?.isRoleBound == true }", "isRoleBoundPredicate = { peerAddress -> centralDriver.getActiveConnection(peerAddress)?.isRoleBound == true }", "BL82"),
        ("android_transport", "responderRemoteLinkInfo[peerAddress] = decoded", "/* responderRemoteLinkInfo[peerAddress] = decoded */", "BL83"),
        ("ios_driver", "guard let data = localLinkInfoProvider(), data.count == BleLinkInfoConstants.linkInfoBytes else {", "if !ensureAdmitted(centralId: centralId) { return .rejectRead(centralId) }\n        guard let data = localLinkInfoProvider(), data.count == BleLinkInfoConstants.linkInfoBytes else {", "BL84"),
        ("ios_transport", "driver.onInboundTimeout(centralId: centralId, expectedGen: effectiveGen)", "/* disabled_onInboundTimeout */", "BL85"),
        ("android_server", "val currentCallback = makeServerCallback(gen)", "/* val currentCallback = makeServerCallback(gen) */", "BL86"),
        ("android_capacity", "data class CapacityLease(", "data class CapacityLeaseMutated(", "BL87"),
        ("ios_driver", 'return .rejectWrite(centralId, "Conflicting LinkInfo write on active relation")', '/* return .rejectWrite(centralId, "Conflicting LinkInfo write on active relation") */', "BL88"),
        ("android_capacity", "val leaseId: Long", "/* val leaseId: Long */", "BL89"),
        ("ios_driver", "let leaseId: UInt64", "/* let leaseId: UInt64 */", "BL89"),
        ("android_transport", "ConcurrentHashMap.newKeySet<RelationKey>()", "ConcurrentHashMap.newKeySet<String>()", "BL90"),
        ("ios_transport", "Set<RelationKey> = []", "Set<String> = []", "BL90"),
        ("android_client", "op.opType == GattOpType.SERVICE_DISCOVERY", "/* op.opType == GattOpType.SERVICE_DISCOVERY */", "BL91"),
        ("android_driver", "data class BleElectionContext(", "/* data class BleElectionContext( */", "BL92"),
        ("ios_driver", "struct BleElectionContext", "/* struct BleElectionContext */", "BL92"),
        ("android_client", "val clientToken: Long = nextClientToken()", "/* val clientToken: Long = nextClientToken() */", "BL93"),
        ("android_transport", "activeClient.clientToken != clientToken", "/* activeClient.clientToken != clientToken */", "BL93"),
        ("android_server", "is BleServerAction.RejectWrite", "/* is BleServerAction.RejectWrite */", "BL94"),
        ("android_test_substrate", "testAndroidServer_MalformedLinkInfo_ReleasesCapacity", "disabled_testAndroidServer", "BL95"),
        ("ios_test_substrate", "testIosLinkInfo_ExactDuplicate_NoCrashNoRebindNoExtraLease", "disabled_testIosLinkInfo", "BL95"),
        ("android_driver", "fun onClientDisconnected(deviceAddress: String, expectedGen: Long = 0L)", "fun onClientDisconnected(deviceAddress: String)", "BL96"),
        ("android_server", "orchestrationDriver?.onClientDisconnected(address)", "/* orchestrationDriver?.onClientDisconnected(address) */", "BL96"),
        ("android_transport", "inboundJobs[peerAddress] = job", "/* inboundJobs[peerAddress] = job */", "BL97"),
        ("android_transport", "fun publishRelation(key: RelationKey", "fun disabled_publish(key: RelationKey", "BL98"),
        ("android_driver", "isExactDuplicate = (existing == remoteInfo)", "isExactDuplicate = existing.nodeHint.contentEquals(remoteInfo.nodeHint)", "BL99"),
        ("ios_driver", "acceptedRemoteLinkInfo[centralId], existing == remoteInfo", "acceptedRemoteLinkInfo[centralId], existing.nodeHint == remoteInfo.nodeHint", "BL100"),
        ("ios_driver", "public func getCentralGeneration(_ centralId: UUID) -> UInt64", "/* getCentralGeneration */", "BL101"),
        ("ios_driver", "public func onCentralUnsubscribed(centralId: UUID, expectedGen: UInt64 = 0)", "public func onCentralUnsubscribed(centralId: UUID)", "BL102"),
        ("ios_transport", "public func publishRelation(_ key: RelationKey", "/* publishRelation */", "BL103"),
        ("ios_transport", "public func processInboundWrite(", "public func processInboundWriteMutated(", "BL104"),
        ("android_client", "op.gattGeneration == gen", "false", "BL105"),
        ("android_test_substrate", "fun testTransportInboundAdmission_SchedulesExactGenerationTimeout", "fun disabled_testTransportInboundAdmission", "BL106"),
        ("ios_test_substrate", "func testIosLinkInfo_SameHintDifferentFlagsRejected", "func disabled_testIosLinkInfo_FlagsRejected", "BL107"),
        ("android_driver", "enum class ServerPeerSlotState", "enum class MutatedServerPeerSlotState", "BL108"),
        ("android_driver", "enum class OutboundPeerSlotState", "enum class MutatedOutboundPeerSlotState", "BL109"),
        ("android_client", "data class GattLifetimeToken(", "data class GattLifetimeTokenMutated(", "BL110"),
        ("android_driver", "data class AcceptDuplicateWrite(", "data class AcceptDuplicateWriteMutated(", "BL111"),
        ("ios_driver", "enum OutboundSlotState", "enum MutatedOutboundSlotState", "BL112"),
        ("ios_driver", "enum InboundSlotState", "enum MutatedInboundSlotState", "BL113"),
        ("ios_driver", "case acceptDuplicateWrite(UUID, Data)", "case acceptDuplicateWriteMutated(UUID, Data)", "BL114"),
        ("android_test_substrate", "testServerLifecycle_ConnectedWhileActiveDoesNotRenumberRelation", "disabled_testServerLifecycle", "BL115"),
        ("ios_test_substrate", "testIosDuplicateBeforeSubscription_ReusesOriginalTimer", "disabled_testIosDuplicate", "BL116"),
        ("android_driver", "    CLOSING,\n    QUARANTINED", "    CLOSING,\n    MUTATED_QUARANTINED", "BL117"),
        ("android_server", "orchestrationDriver?.onClientDisconnected(address)", "/* mutated disconnected */", "BL118"),
        ("android_client", "fun makeGattCallback(token: GattLifetimeToken)", "fun makeGattCallbackMutated(token: GattLifetimeToken)", "BL119"),
        ("ios_transport", "class RelationPeripheralDelegate: NSObject, CBPeripheralDelegate", "class RelationPeripheralDelegateMutated: NSObject, CBPeripheralDelegate", "BL120"),
        ("ios_transport", "public struct OutboundPhysicalLifetime: Sendable", "public struct OutboundPhysicalLifetimeMutated: Sendable", "BL121"),
        ("ios_transport", "currentTransportEpoch += 1", "/* currentTransportEpoch += 1 */", "BL122"),
        ("ios_transport", "case .acceptWrite, .acceptDuplicateWrite, .acceptWriteAndDuplexReady:", "case .acceptWrite, .acceptWriteAndDuplexReady:", "BL123"),
        ("ios_driver", "case active(UInt64)", "case activeMutated(UInt64)", "BL124"),
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
            "android_driver": ANDROID_DRIVER_PATH,
            "android_capacity": ANDROID_CAPACITY_PATH,
            "android_delivery_repo": ANDROID_DELIVERY_REPO_PATH,
            "android_mesh_module": ANDROID_MESH_MODULE_PATH,
            "android_transport": ANDROID_TRANSPORT_PATH,
            "android_snapshot": ANDROID_SNAPSHOT_PATH,
            "android_test_substrate": ANDROID_TEST_SUBSTRATE_PATH,
            "android_mesh_node": ANDROID_MESH_NODE_PATH,
            "android_wirev2": ANDROID_WIREV2_PATH,
            "android_record_codec": ANDROID_RECORD_CODEC_PATH,
            "ios_role": IOS_ROLE_PATH,
            "ios_coord": IOS_COORD_PATH,
            "ios_conn": IOS_CONN_PATH,
            "ios_driver": IOS_DRIVER_PATH,
            "ios_transport": IOS_TRANSPORT_PATH,
            "ios_snapshot": IOS_SNAPSHOT_PATH,
            "ios_message_store": IOS_MESSAGE_STORE_PATH,
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
                android_driver_path=tmp_files["android_driver"],
                android_capacity_path=tmp_files["android_capacity"],
                android_delivery_repo_path=tmp_files["android_delivery_repo"],
                android_mesh_module_path=tmp_files["android_mesh_module"],
                android_transport_path=tmp_files["android_transport"],
                android_snapshot_path=tmp_files["android_snapshot"],
                android_test_substrate_path=tmp_files["android_test_substrate"],
                android_mesh_node_path=tmp_files["android_mesh_node"],
                android_wirev2_path=tmp_files["android_wirev2"],
                android_record_codec_path=tmp_files["android_record_codec"],
                ios_role_path=tmp_files["ios_role"],
                ios_coord_path=tmp_files["ios_coord"],
                ios_conn_path=tmp_files["ios_conn"],
                ios_driver_path=tmp_files["ios_driver"],
                ios_transport_path=tmp_files["ios_transport"],
                ios_snapshot_path=tmp_files["ios_snapshot"],
                ios_message_store_path=tmp_files["ios_message_store"],
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

    print("BLE link substrate structural controls: ALL PASSED (BL01-BL124).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
