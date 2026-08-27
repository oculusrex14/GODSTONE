# ADR-002 — BLE roles, record framing, and the Noise handshake driver

**STATUS: ACCEPTED / PHASE C8.4C RECORD LAYER FROZEN; PHASE C8.4D1-A1 LINKINFO AMENDMENT ACCEPTED / FROZEN; PHASE C8.4D1-R2 OPEN** (27 Aug 2026)
Implementation:
- Phase C8.4C canonical BLE record layer (types, balanced-stride codec, fragmenter, bounded reassembler with injected clock, duplicate suppression, conflict rejection, encrypt-then-fragment semantic verification, 32/229/197 handshake composition tests, independent Python reference `wire/ble_record_reference.py`, and locked vectors `wire/ble_record_vectors.json`) is IMPLEMENTED and FROZEN.
- Phase C8.4D1-A1 LinkInfo Role-Binding Amendment (Connect-First / Elect-Before-Handshake, generated `LINK_INFO_UUID`, 13-byte `BleLinkInfoV1` canonical characteristic payload, provisional GATT connection state machine, simultaneous connect deterministic elimination proof, CBPeripheral/CBCentral identifier separation, and ADR-003 security binding) is ACCEPTED and FROZEN.
- Phase C8.4D1-R2 (Implementation of LinkInfo exchange, Android GATT lifecycle repairs, and substrate closure) is OPEN.
- Phase C8.4D2 (trusted handshake driver) is OPEN / NOT STARTED.
- Full link enablement (radio/GATT drivers) remains open behind `LINK_LAYER_READY=false` / `linkLayerReady=false`.

---

## 1. The decision, in one line

**A four-field record layer outside the encrypted frame; encrypt-then-fragment; connect-first provisional GATT discovery with pre-handshake LinkInfo characteristic role election; and UUID-only baseline advertising.**

---

## 2. Platform constraints and the discovery amendment

### 2.1 The Apple CoreBluetooth platform limitation
Authoritative platform evaluation confirms that stock Apple `CBPeripheralManager.startAdvertising(_:)` supports only:
- `CBAdvertisementDataServiceUUIDsKey`
- `CBAdvertisementDataLocalNameKey`

Any additional keys specified in the advertising dictionary (including `CBAdvertisementDataServiceDataKey` and manufacturer data keys) are ignored by iOS peripheral advertising. Furthermore, iOS automatically manages scan responses, allowing only the local name string. Stock iOS **cannot emit arbitrary 13-byte service data in a scan response**.

Therefore, the original ADR-002 assumption that both platforms can broadcast 13-byte discovery metadata over the air *before* connection is physically unimplementable under stock iOS CoreBluetooth.

### 2.2 Rejection of "Central == Noise Initiator" alone
A simplistic rule where "every BLE Central is automatically the Noise Initiator" was evaluated and **rejected**.
Because all GODSTONE nodes are simultaneously central-capable (scanning/connecting) and peripheral-capable (advertising/listening), two encountering peers $A$ and $B$ frequently establish crossing physical connections:
1. $A$ (Central) $\rightarrow$ $B$ (Peripheral)
2. $B$ (Central) $\rightarrow$ $A$ (Peripheral)

If Central == Initiator were the sole rule, both physical links would survive and two independent Noise handshakes would begin simultaneously. This recreates the duplicate-link collision and resource race that deterministic role election was designed to eliminate.

---

## 3. Connect-First / Elect-Before-Handshake LinkInfo Architecture (Phase C8.4D1-A1)

To resolve platform limitations while preserving 100% deterministic link deduplication and identity binding, GODSTONE amends discovery and role binding to a **Connect-First / Elect-Before-Handshake** architecture:

```
UUID-only Discovery
    │
    ▼
Provisional GATT Connection
    │
    ▼
LinkInfo Characteristic Exchange (link_info_uuid)
    │
    ▼
Deterministic node_hint Role Election (unsigned lexicographic)
    │
    ├──────────────────────────────────────────────┐
    ▼                                              ▼
Local is INITIATOR (local < remote)          Local is RESPONDER (local > remote)
    │                                              │
Write Local LinkInfo to Peripheral                 Cancel Wrong-Direction Central Link
    │                                              │
Await Write Acknowledgment                         (Peripheral accepts LinkInfo from remote)
    │                                              │
    ▼                                              ▼
Link State: ROLE_BOUND                        Link State: ROLE_BOUND
    │                                              │
    └──────────────────────┬───────────────────────┘
                           │
                           ▼
                 Trusted Noise Handshake
                   (HS1 -> HS2 -> HS3)
                           │
                           ▼
                  READY / Sealed Data
```

### 3.1 Provisional Connection Semantics
Discovery of the canonical GODSTONE Service UUID (`6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10`) authorizes **only a provisional GATT connection**. It does NOT authorize:
- Emitting Noise HS1
- Transmitting application DATA records
- Establishing identity trust
- Marking the node or transport READY
- Routing or peer delivery claims

### 3.2 Canonical LinkInfo Characteristic (`link_info_uuid`)
A single canonical GATT characteristic is generated from `wire/wire_v2.yaml`:
- **`LINK_INFO_UUID`**: `6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10`
- Properties: `READ` (peripheral exposes local LinkInfo) | `WRITE` (central writes its LinkInfo with acknowledgment).
- Nature: Pre-handshake, unencrypted GATT control characteristic. It is **not** a `BleRecord` channel and never carries `FrameV2` frames.

### 3.3 Canonical 13-Byte `BleLinkInfoV1` Layout
`BleLinkInfoV1` defines the 13-byte authoritative payload exchanged over the `link_info_uuid` characteristic:

```
off size field
0   1    protocol_version   0x02
1   1    flags              bit0 SOS_PRESENT   bit1 BULK_CAPABLE
                            bit2 POWER_CONSTRAINED   bit3 VERIFIED_ONLY
                            bit4 CLOCK_UNTRUSTED (ADR-001 §3.2)
2   4    node_hint          first 4 bytes of node_id (unsigned comparison)
6   6    bloom_digest_short truncated bloom filter of held msg_ids
12  1    queue_depth        saturating, 0-255
```

### 3.4 Characteristic Direction & Role Binding Protocol
1. **Central**:
   - Provisionally connects to peripheral upon discovering service UUID.
   - Discovers services and reads the peripheral's `link_info_uuid` characteristic.
   - Validates exact length (13 bytes) and version (`0x02`).
   - Runs `BleRoleElection.elect(localHint, remoteHint)`:
     - **If `localHint < remoteHint`**: Local central is elected **`INITIATOR`**. Central writes its local `BleLinkInfoV1` to the peripheral's `link_info_uuid` characteristic using an acknowledged write request. Upon write acknowledgment, the link transitions to **`ROLE_BOUND`** and Central is authorized to begin Noise HS1.
     - **If `localHint > remoteHint`**: Local central is elected **`RESPONDER`**. This indicates the wrong-direction physical connection. Central **immediately cancels/disconnects** the link without sending its LinkInfo and without emitting HS1.
     - **If `localHint == remoteHint`**: **Tie condition / clone collision**. Fails closed; cancels connection immediately without handshake.
2. **Peripheral**:
   - Exposes local `BleLinkInfoV1` on `link_info_uuid` READ requests.
   - Accepts remote Central `BleLinkInfoV1` on `link_info_uuid` WRITE requests.
   - Validates length (13 bytes), version (`0x02`), and asserts `remoteHint < localHint`.
   - If valid, local role becomes **`RESPONDER`**, binds `remoteHint` to the incoming connection, and transitions link state to **`ROLE_BOUND`** (ready to receive HS1).

### 3.5 Crossing-Connection Deterministic Resolution Proof
Given two dual-role nodes $A$ and $B$ with hints $A < B$:
- **Connection 1 ($A$ Central $\rightarrow$ $B$ Peripheral)**:
  - $A$ reads $B$'s LinkInfo. $A$ computes $A < B$ $\rightarrow$ elected `INITIATOR`.
  - $A$ writes its LinkInfo to $B$.
  - $B$ receives $A$'s LinkInfo, verifies $A < B$ $\rightarrow$ local role `RESPONDER`.
  - Both sides mark Connection 1 **`ROLE_BOUND`**.
- **Connection 2 ($B$ Central $\rightarrow$ $A$ Peripheral)**:
  - $B$ reads $A$'s LinkInfo. $B$ computes $B > A$ $\rightarrow$ elected `RESPONDER`.
  - $B$ immediately cancels Connection 2.
  - $A$ never receives a LinkInfo write on Connection 2 and rejects any premature HS traffic.
- **Result**: Exactly **one** canonical physical connection survives. Zero duplicate links. No race conditions. No reliance on platform MAC, UUID, RSSI, timing, or random tie-breakers.

### 3.6 Transport Identifier Separation
- **`CBPeripheral.identifier`** (Central handle) and **`CBCentral.identifier`** (Peripheral handle) are transport-local identifiers.
- Under the amended protocol, no platform equality between these UUIDs is assumed or required.
- Actual authenticated peer identity is established in Phase C8.4D2 by binding the observed `node_hint` to the cryptographic `IdentityBinding` (Noise static key + signed node identity) in accordance with ADR-003.

---

## 4. Encrypt-then-fragment

| | encrypt-then-fragment | fragment-then-encrypt |
|---|---|---|
| Noise nonce granularity | one per **record** — matches the spec as written | one per **fragment** — needs a new AAD construction binding index/count |
| integrity | all-or-nothing; a corrupted fragment fails the whole record | per-fragment, so partial plaintext can reach the reassembler |
| memory | bounded by MAX_RECORD | bounded by MAX_RECORD |
| retransmit cost | whole record | single fragment |
| new cryptography required | **none** | a specified per-fragment AEAD |

**Decision: encrypt-then-fragment.** All-or-nothing integrity ensures that partially-decrypted or corrupt data never reaches the message store or routing layer.

---

## 5. The record layer (C8.4C — Frozen)

Outside the Noise ciphertext, because handshake messages must be carried before a session exists. 8-byte header:

```
off size field
0   1    magic          0x47
1   1    type           HS1 0x11  HS2 0x12  HS3 0x14  DATA 0x18  CLOSE 0x21
                        (even parity, >= 2 Hamming apart, same rule as frames)
2   1    record_seq     connection-local, wraps at 256
3   1    frag_index     0-based
4   1    frag_count     1-64
5   2    total_len      reassembled length, uint16 BE
7   1    header_check   XOR of bytes 0..6

bounds
  MAX_RECORD        16384 bytes reassembled
  MAX_FRAGMENTS     64
  REASSEMBLY_TIMEOUT 30 s   (bitchat field value)
  MAX_CONCURRENT    4 records in flight per peer  -> 64 KB peak per peer
```

---

## 6. Transport Connection Lifecycle State Machine

The amended transport lifecycle defines the following explicit states:

```
DISCOVERED
    │ (provisional connect)
    ▼
PROVISIONAL_CONNECTING
    │
    ▼
PROVISIONAL_CONNECTED
    │
    ▼
LINK_INFO_READING  ──(elected responder)──► CLOSING ──► CLOSED
    │ (elected initiator)
    ▼
LINK_INFO_WRITING
    │ (write acknowledged)
    ▼
ROLE_BOUND
    │ (Phase C8.4D2)
    ▼
HANDSHAKE_IN_PROGRESS
    │ (Noise + IdentityBinding verified)
    ▼
READY  ──(trust violation / pin mismatch)──► QUARANTINED
```

- **`ROLE_BOUND`** is strictly required before any Noise HS record (HS1/HS2/HS3) may be sent or processed.
- **`READY`** is strictly required before any application `DATA` record may be sealed, sent, or decrypted.

---

## 7. Non-Normative Advertisement Semantics & Open Substrate Items

### 7.1 Advertisement Baseline
- **Baseline for both platforms**: Primary advertisement carries the GODSTONE Service UUID only (`CBAdvertisementDataServiceUUIDsKey` on iOS). No local name is broadcast, preserving privacy.
- **Optional Android Optimization**: Android may optionally emit `BleLinkInfoV1` in the scan response to allow pre-filtering and UI hints. However, the `link_info_uuid` characteristic remains the sole normative authority for role election and handshake binding.

### 7.2 Open Implementation Items for Phase C8.4D1-R2
1. **Android Snapshot Authority**: In `MeshNode.kt`, inject a live `digestProvider` snapshot rather than falling back to synthetic node hint bytes in `BleTransport`.
2. **Android GATT Client Hardening**:
   - Verify CCCD descriptor write status before completing client connection.
   - Check `requestMtu()` return value and handle MTU callback failures gracefully.
   - Enforce bounded timeouts for GATT connect and ATT write operations.
3. **LinkInfo Characteristic Drivers**: Implement GATT server READ/WRITE handlers for `LINK_INFO_CHAR_UUID` on Android and iOS.

---

## 8. Acceptance Criteria

- [x] Canonical `link_info_uuid` added to `wire/wire_v2.yaml` and generated identically into Android and iOS codecs.
- [x] Connect-First LinkInfo role election protocol formally specified and proven for simultaneous crossing connections.
- [x] `BleLinkInfoV1` 13-byte format defined with cross-platform encoding/decoding parity.
- [x] Property tests: 1000 randomized unequal hint pairs yield exactly one canonical link.
- [x] Missing advertisement service data does not prohibit provisional connection.
- [x] All structural controls (BL01–BL30+) verified green with 100% negative mutation selftests.
- [x] Phase C8.4C record layer remains frozen.
- [x] Phase C8.4D2 trusted handshake integration remains OPEN / NOT STARTED.
- [x] `LINK_LAYER_READY = false` and `linkLayerReady = false` strictly preserved.
