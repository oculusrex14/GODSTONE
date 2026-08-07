# GMP/2.1 Android Runtime Inventory

Companion to `docs/adr/ADR-001-canonical-wire.md` (ACCEPTED — defines GMP/2.1)
and `docs/adr/ADR-008-android-canonical-gmp21-runtime.md` (the Android
realization + A-01 closure rule). This inventory enumerates the **current** mesh
runtime surface and the **target** GMP/2.1 components, so the Stage-2 patch
series (14–21) is grounded in what exists rather than invented.

It is an inventory, **not** a verdict. It does not close A-01. A-01 advances only
per the §20 rule in ADR-008 (OPEN → IMPLEMENTED_LOCAL_VERIFIED on repo-controlled
execution evidence; short of CLOSED until real Android↔iOS device interop).

> **Stage 3 reconciliation note.** This inventory was written **before** the
> Stage 2 patch series (14–21) was applied, so the "current" column below is the
> **pre-Stage-2 baseline**, not the present state. On `remediation/stage-2-gmp21`
> and continued on `remediation/stage-3-durability`, the patches are applied:
> `wire/Frame.kt` is **deleted** (patch 20) — the Android runtime is **not** live
> on GMP/1; it routes on the generated `FrameV2` (`Router.kt` imports
> `io.godstone.mesh.wire.v2.FrameV2`, `MeshNode` decodes `FrameV2`); the Noise
> prologue is `"GMP2"` (`NoiseSession.kt:212`). The "target (patch)" column is
> therefore realized for the frame path and prologue. The msg_id byte-order,
> iOS msg_id construction, Bloom digest parity, and cross-platform PoW semantics
> are being made byte-identical in Stage 3 Phase C; until that lands and both
> production-path builders execute the locked vectors, those rows stay
> "target/in-progress" and ADR-008 criteria 4–6 are not ticked green. A-01
> remains OPEN (clean shipping path is not GMP/2.1 canonical-frame device
> evidence).

---

## 1. Current Android mesh runtime (`android/mesh/src/main/java/io/godstone/mesh/`)

> Pre-Stage-2 baseline (see reconciliation note above). On the remediation
> branches `wire/Frame.kt` is **deleted** and the runtime routes on `FrameV2`;
> this section is retained as the baseline-of-record for the patch series.

The Android runtime **was** **GMP/1**, live on `wire/Frame.kt`. `LINK_LAYER_READY =
false` in `MeshNode`, so the radio is off; but the code path compiles and is unit-
tested on the GMP/1 frame.

| component | path | current responsibility | GMP/2.1 target (patch) |
|---|---|---|---|
| `wire/Frame.kt` | `wire/Frame.kt` | **GMP/1** 20B header, `version=0x01`, 8B `Long` msg_id, 6B timestamp, types 0x01..0x0A; `FrameType`/`Priority` enums; `Priority.requiresProofOfWork = GROUP‖BROADCAST` | **DELETE** (patch 20); route through `FrameV2` |
| `wire/v2/WireV2.kt` | `wire/v2/WireV2.kt` | **GENERATED** GMP/2 32B header, magic 0x4753, version 0x02, 16B msg_id, 4B routing_tag, CRC-16/CCITT, even-parity types 0x11..0xF0; **nothing imports it** | make it the live frame path (patch 19) |
| `router/Router.kt` | `router/Router.kt` | epidemic DTN router on `Frame`; inbound gate = `PeerGovernor`→dedup(LRU 16384)→age(14d)→TTL→PoW→persist+emit; bloom anti-entropy; sealed MESSAGE/SOS build/open | operate on `FrameV2`; bloom from durable held set (patch 19) |
| `router/BloomDigest.kt` | `router/BloomDigest.kt` | 4096-bit Bloom, 4 rounds, hash input `Long(8)‖Int(4)` = 12B (BLAKE2s-64); 16B `shortDigest()` | `BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096`, 20B, golden vectors (patch 15/19) |
| `router/ProofOfWork.kt` | `router/ProofOfWork.kt` | 20-bit BLAKE2s PoW over `payload‖msg_id‖timestamp‖type_code`; `mine` mutates `msg_id` (no nonce field in GMP/1 header) | nonce inside sealed payload; `HAS_POW` flag; both platforms verify (patch 17) |
| `store/MessageStore.kt` | `store/MessageStore.kt` | `MessageStore` interface + `SqliteMessageStore` (SQLCipher, 256B Keystore key); schema `held_frames(msg_id INTEGER PK, type, ttl, priority, timestamp, payload, received_from, received_at)`; bounded eviction (SOS last); additive `onUpgrade`; `panicWipe`; `InMemoryMessageStore` for tests. **"still uses the legacy GMP/1 logical schema until ADR-001/M1-wire"** | schema v2: 16B BLOB msg_id, receipt-monotonic retention, persist-before-forward, delete-on-ACK, hard-cap, panic wipe (patch 18; ADR-004) |
| `crypto/NoiseSession.kt` | `crypto/NoiseSession.kt` | `Noise_XX_25519_ChaChaPoly_BLAKE2s`; prologue `"GMP1"‖hints`; replay window; rekey | prologue `"GMP2"‖hints`; regenerate + re-pin vectors (patch 20; ADR-001 §7) |
| `crypto/SessionManager.kt` | `crypto/SessionManager.kt` | per-peer Noise registry; `seal`/`open` return null with no plaintext fallback | unchanged (operates on frame bytes) |
| `identity/Identity.kt` | `identity/Identity.kt` | Ed25519 signing + X25519 DH in EncryptedSharedPreferences (Keystore); `nodeId = BLAKE2s-128(ed25519Pub)` 16B; `nodeHint = nodeId[0..4)`; BIP-39 callSign; `panicWipe` | `nodeId` feeds msg_id derivation (patch 16) |
| `seal/SealedSender.kt` | `seal/SealedSender.kt` | sealed sender L4; `routingTag = BLAKE2s-32(recipientNodeId ‖ epochDay)` 4B daily; ephemeral X25519 → `K_seal = BLAKE2s(shared‖"godstone-seal-v2")` → AES-GCM over `senderNodeId‖plaintext`; `open` returns null indistinguishably | PoW nonce + `created_at` ride inside the sealed plaintext (patch 17) |
| `MeshNode.kt` | `MeshNode.kt` | composition root; `LINK_LAYER_READY=false`; SOS = `router.buildSos(payload, SecureRandom().nextLong())`→persist→`frame.encode()`→`ble.send`; inbound `Frame.decode`→`router.onFrameReceived` | `FrameV2`; content-derived msg_id (patch 16/19) |
| `MeshService.kt` | `MeshService.kt` | foreground service `@AndroidEntryPoint`; injects `MeshNode`; power-state re-eval 60s; static notification (ADR-005 OPEN) | unchanged |
| `abuse/PeerGovernor.kt` | `abuse/PeerGovernor.kt` | per-priority token buckets + trust scoring w/ exponential backoff; `allowInbound` before parse | retained on `FrameV2` |
| `transport/BleTransport.kt` | `transport/BleTransport.kt` | BLE scaffold; references `FrameV2.VERSION`/UUIDs for scan-response only; `sessions.seal`/`open` (no plaintext fallback) | wire framing to `FrameV2` |
| `transport/WifiAwareTransport.kt` | `transport/WifiAwareTransport.kt` | Wi-Fi Aware (Android-only bulk); `SERVICE_NAME = "godstone-gmp1"` | rename / drop legacy name (patch 20) |

## 2. Current iOS mesh runtime (`ios/Godstone/Sources/GodstoneMesh/`)

iOS is **already on GMP/2** (`FrameV2`), but the runtime is memory-only and
incomplete relative to ADR-001/004.

| component | path | current | GMP/2.1 target (patch) |
|---|---|---|---|
| `WireV2.swift` | `WireV2.swift` | **GENERATED** GMP/2, byte-identical to Android `WireV2.kt` | canonical (patch 14/15) |
| `Router.swift` | `Router.swift` | epidemic DTN on `FrameV2`; dedup `LruSet<Data>` 16384; in-memory queue (max 512, SOS-first); **no PoW, no age expiry (v2 has no timestamp), bloom from dedup window not held set, no DIGEST/WANT** | PoW verify (patch 17); durable store + bloom from held set (patch 18/19) |
| `MeshNode.swift` | `MeshNode.swift` | composition root; `linkLayerReady=false`; SOS = 16 random bytes msgId + Ed25519 sig over `msgId‖"SOS1"‖payload`, flags `ACK_REQ‖RELAY_OK`; memory-only | content-derived msg_id (patch 16); durable store (patch 18) |
| `MeshIdentity.swift` | `MeshIdentity.swift` | Ed25519+X25519 in Keychain; `nodeId = BLAKE2s-128(ed25519Pub)` (matches Android post-V4) | feeds msg_id derivation (patch 16) |
| `NoiseSession.swift` | `NoiseSession.swift` | `Noise_XX_25519_ChaChaPoly_BLAKE2s` via CryptoKit; prologue `"GMP1"‖hints` (line 89) | prologue `"GMP2"`; regenerate + re-pin (patch 20) |
| `SessionManager.swift` | `SessionManager.swift` | per-peer Noise registry; no plaintext fallback | unchanged |
| `BleTransport.swift` | `BleTransport.swift` | CoreBluetooth; UUIDs from `FrameV2` constants; `sessions.seal`/`open`; no record-layer fragmentation yet (ADR-002) | unchanged by Stage 2 |
| `BulkTransport.swift` | `BulkTransport.swift` | deliberately unavailable stub (`isAvailable=false`); ADR-006 | unchanged (bulk NOT enabled) |

## 3. Codegen + conformance infra (cross-platform)

| artifact | path | role |
|---|---|---|
| `wire/wire_v2.yaml` | `wire/wire_v2.yaml` | **single source of truth**; 32B header, types, flags, priority (3-bit `PRIORITY_MASK=0x0700`), `sos_requirements` |
| `wire/codegen.py` | `wire/codegen.py` | emits Kotlin+Swift+Python codecs + `golden_vectors.json`; asserts parity, Hamming≥2, no-v1-reuse, `verify_priority_mask` (ADR-001 §3.1) |
| `wire/gen/WireV2.{kt,swift}` | `wire/gen/` | generated codecs (copied to `android/.../wire/v2/` and `ios/.../`) |
| `wire/gen/wire_v2_codec.py` | `wire/gen/` | Python reference codec used to build golden vectors |
| `wire/golden_vectors.json` | `wire/golden_vectors.json` | golden wire vectors (every type, bloom rounds, edge values) |
| `ci/check_parity.py` | `ci/check_parity.py` | Invariants A–G; A = wire codecs regenerate byte-identically (**PASS**) |
| `crypto/gen_vectors.py` | `crypto/gen_vectors.py` | regenerates Noise handshake vectors |
| `crypto/handshake_vectors.json` | `crypto/handshake_vectors.json` | pinned Noise_XX vectors (re-pinned on prologue change) |
| `crypto/port_vectors.json` + `.py` | `crypto/` | port vectors (transcript-hash) |
| `crypto/cacophony_vectors.json` + `cacophony.py` | `crypto/` | **external** cacophony conformance (A-06; UNPINNED → A-06 OPEN) |
| `crypto/test_conformance.py` | `crypto/test_conformance.py` | conformance runner; asserts `prologue == b"GMP1"‖hints` (line 100) |

## 4. Current parity state (`ci/check_parity.py`)

| invariant | status | note |
|---|---|---|
| A wire codecs byte-identical | **PASS** | codegen is the enforcement lever |
| B no self-grounding eval | **PASS** | |
| C archive present | **FAIL** | `dist/archive_medium.db` missing — blocked by llama.cpp constraint; out of wire scope |
| D independent Noise vectors | **FAIL** | no approved external cacophony fixture; A-06 OPEN (external gate) |
| E tier tables agree | **FAIL** | separate cross-platform finding |
| F no unresolved Kotlin refs | **PASS** | 50 files, 0 unresolved |
| G integration fail-closed | **PASS** | unfinished mesh paths fail-closed |

**Stage 2 does not chase C, D, or E:** C is the model archive (shipping critical
path, llama.cpp-blocked); D is an external gate (A-06); E is a separate finding.
Stage 2 makes A, F, G stay green and adds the runtime realization.

## 5. msg_id / PoW / prologue — where the live code is

- **msg_id generation:** Android `MeshNode.broadcastSos` →
  `router.buildSos(payload, SecureRandom().nextLong())` (`MeshNode.kt`); iOS
  `MeshNode.broadcastSos` → `SecRandomCopyBytes(16)` (`MeshNode.swift`). Neither
  is content-derived. → patch 16: `BLAKE2s-128(sender ‖ created_at_le ‖ payload)`.
- **PoW:** only Android `ProofOfWork.kt` (`verify` line 31, `mine` line 65);
  `Router.kt:59` enforces for GROUP/BROADCAST; iOS has none. `mine` mutates
  `msg_id` — breaks once msg_id is a content hash. → patch 17: nonce in sealed
  payload; both platforms verify.
- **Noise prologue `b"GMP1"`:** `android/.../NoiseSession.kt:212`,
  `ios/.../NoiseSession.swift:89`, `crypto/derivation.py:32`, `crypto/noise_ref.py:45`,
  `crypto/test_conformance.py:100`. → patch 20: `"GMP2"` + regen + re-pin D
  (ADR-001 §7; ADR-007 SHA-256 deferred — see ADR-008 §2.3).

## 6. Target component map after Stage 2 (patches 14–21)

After the series, the Android runtime shares the canonical GMP/2.1 path with
iOS: both route on `FrameV2`; both derive `msg_id = BLAKE2s-128(sender ‖
created_at_le ‖ payload)`; both place the PoW nonce in the sealed payload; both
compute `bloom = BLAKE2s-64(msg_id ‖ uint32_be(round)) mod 4096`; both use a
schema-v2 durable store with receipt-monotonic retention; both bind the `"GMP2"`
Noise prologue; both reproduce `wire/golden_vectors.json` and the regenerated
`crypto/handshake_vectors.json`. A-01 advances to IMPLEMENTED_LOCAL_VERIFIED
(repo-controlled); it remains short of CLOSED until real device interop.