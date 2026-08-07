# ADR-008 — Android canonical GMP/2.1 runtime realization

**STATUS: OPEN (implementation tracked as the Stage-2 patch series 14–21).**
Foundation: **ADR-001 (ACCEPTED)** defines GMP/2.1 as the canonical runtime
format on both platforms and deletes GMP/1. This ADR scopes HOW the Android
runtime is brought onto that canonical frame path, and the rule under which
A-01 may advance. It does not re-open any ADR-001 decision.

---

## 1. Context

ADR-001 is accepted but the Android runtime is not yet on the canonical frame
path. The codegen contract is already green — `wire/wire_v2.yaml` is the single
source of truth and `wire/codegen.py` regenerates byte-identical Kotlin + Swift
codecs (`ci/check_parity.py` Invariant A passes). The gap is the **runtime**, not
the codec:

| concern | Android (live) | iOS (live) | ADR-001 target |
|---|---|---|---|
| frame | `wire/Frame.kt` GMP/1, 20B, `version=0x01` | `WireV2.swift` GMP/2, 32B | GMP/2.1 `FrameV2` on both |
| msg_id | `SecureRandom().nextLong()` (8B random) | 16 random bytes | `BLAKE2s-128(sender ‖ created_at_le ‖ payload)`, 16B |
| PoW | 20-bit BLAKE2s, `mine` mutates msg_id | none | nonce inside **sealed payload**; both platforms verify |
| bloom | `Long(8)‖Int(4)` = 12B | `Data(16)‖UInt8` = 17B | `BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096`, 20B |
| store | SQLCipher `held_frames(msg_id INTEGER PK)`, GMP/1 schema | none (memory queue) | schema v2: 16B BLOB msg_id, receipt-monotonic retention |
| Noise prologue | `"GMP1"‖hints` | `"GMP1"‖hints` | `"GMP2"‖hints` (§7) |
| router | `Router` on `Frame`, with `PeerGovernor`/PoW/age/TTL/bloom | `Router` on `FrameV2`, memory-only | both on `FrameV2`, same anti-entropy digest |

The generated `FrameV2` already exists in the Android tree
(`wire/v2/WireV2.kt`) but **nothing imports it** — `Router`, `MeshNode`,
`MessageStore`, `BleTransport` all use the GMP/1 `Frame`. iOS is coherently on
`FrameV2`; Android is the laggard.

## 2. Decision

Bring the Android runtime onto the generated GMP/2.1 `FrameV2` path as a
single atomic change, per ADR-001 §5 ("there is nothing to migrate; delete
`Frame.kt`, create the store fresh at schema v2, write no migration code, add a
build assertion that no v1 symbol survives"). The change is atomic because
`msg_id` widens from an 8-byte `Long` to a 16-byte content-derived BLOB, which
simultaneously changes `MessageStore`'s primary key, `BloomDigest`'s hash input,
`ProofOfWork`'s preimage, and the `Router`/`MeshNode` API surface — a partial
landing leaves the tree unable to compile or to round-trip a frame.

### 2.1 Patch series (Stage 2)

The realization is split into reviewable patches that **apply in order** and are
each execution-verified by `scripts/verify_android_phase0.sh` (the :mesh unit
tests) plus the Python conformance runners — not static-only:

1. **14 — gmp21-generator-and-drift.** Confirm `wire_v2.yaml` is the one
   normative source; both codecs generated; Invariant A green; codegen's
   `verify_priority_mask` (ADR-001 §3.1) and Hamming/parity/no-v1-reuse
   assertions are the build gate. (Largely already green; this patch makes the
   generated `FrameV2` the Android compile target and removes hand-edits.)
2. **15 — frame-validation-and-vectors.** Cross-platform golden vectors for
   every type, both bloom rounds, and edge values (ttl 0/16, payload 0/60000,
   all priorities); both platforms reproduce `wire/golden_vectors.json` in
   unit tests (NOT self-generated from the Kotlin/Swift under test).
3. **16 — message-id.** `msg_id = BLAKE2s-128(sender_node_id ‖ created_at_le ‖
   payload)`, 16 bytes, shared derivation on both platforms; duplicate
   submissions collapse in the dedup cache.
4. **17 — proof-of-work.** PoW nonce moves into the sealed payload (not the
   id); both platforms implement + verify; `HAS_POW` flag wired.
5. **18 — android-store.** `MessageStore` schema v2: 16B BLOB msg_id,
   receipt-monotonic retention (no header timestamp; `created_at` inside the
   sealed payload), persist-before-forward, delete-on-authenticated-ACK, hard-cap
   eviction (SOS last), panic wipe. Satisfies ADR-004 exit criteria 1,3,4,5,6
   where repo-controlled.
6. **19 — router-and-meshnode.** `Router` and `MeshNode` operate on `FrameV2`;
   bloom anti-entropy from the durable held set; `PeerGovernor` retained.
7. **20 — remove-legacy-gmp1-runtime.** Delete `wire/Frame.kt`; re-bind the
   Noise prologue `"GMP1"→"GMP2"` on both platforms (ADR-001 §7); regenerate
   `crypto/handshake_vectors.json` and re-pin Invariant D **in the same patch**;
   add the build assertion that no v1 symbol (`Frame`, `FrameType`,
   `PROTOCOL_VERSION=0x01`, `godstone-gmp1`) resolves.
8. **21 — cross-platform-conformance.** Both platforms reproduce the golden
   wire vectors + the canonical bloom rounds + the Noise `GMP2` transcript; the
   anti-entropy digest is byte-identical from the same held set (ADR-004 exit
   criterion 6).

### 2.2 Shipping path is NOT touched

GMP/2.1 is the **dormant `:mesh` runtime**. The LIGHT shipping flavor keeps
`MESH_ENABLED=false SOS_ENABLED=false BULK_TRANSFER_ENABLED=false`; `:app`
depends on `:core`+`:llm` only (NOT `:mesh`); the dormant Mesh/SOS UI screens
stay physically relocated under `src/main/dormant/java` (patch 12). The
shipping-path gate (`ci/check_shipping_path.py`) continues to prove the LIGHT
path has no Mesh/GMP dependency edge. Stage 2 enables the canonical wire
**runtime**; it does **not** enable Mesh/SOS/bulk on the shipping path.

### 2.3 Cipher-suite deferral (ADR-007)

ADR-001 §7 changes the Noise prologue to `"GMP2"`. ADR-007 (OPEN, strong
recommendation) would land that change **together with** a BLAKE2s→SHA-256
cipher-suite change (`Noise_XX_25519_ChaChaPoly_SHA256`) because the prologue
change invalidates every pinned vector anyway. ADR-007 is **not accepted**; this
ADR implements only the ACCEPTED ADR-001 §7 (prologue `"GMP2"`, BLAKE2s
preserved, vectors regenerated + Invariant D re-pinned). The SHA-256 suite
change is a separate decision tracked under ADR-007; when it is accepted it
will re-pin the vectors again. Landing the prologue first is faithful to the
ACCEPTED decision and does not preclude the later suite change.

## 3. Acceptance criteria (repo-controlled)

The Android GMP/2.1 runtime realization is **IMPLEMENTED_LOCAL_VERIFIED** when
all of the following are green by execution (not static review):

- [x] `wire/codegen.py` regenerates both codecs; `ci/check_parity.py` Invariant A
      passes (byte-identical); `verify_priority_mask` is a build gate.
      (patch 14: `--selftest` fired negative control + wired into Invariant A;
      mutation-verified; A ok; byte-identical regen holds.)
- [x] cross-platform golden vectors (`wire/golden_vectors.json`) for every
      type, both bloom rounds, and edge values; reproduced by :mesh and iOS
      unit tests (expected values pinned, not self-generated).
      (patch 15: 13 vectors in `:mesh` `WireV2VectorTest` + iOS
      `WireV2VectorTests`; patch 21: iOS suite executed, 13/13.)
- [x] `Router`/`MeshNode`/`MessageStore` operate on `FrameV2`; no v1 symbol
      resolves (build assertion).
      (patch 16: cutover deletes `wire/Frame.kt`, Router/MeshNode/MessageStore
      on `FrameV2`; patch 20: Invariant H fails the build if any GMP/1 symbol
      `Frame`/`FrameType` survives. Runner PASS, H ok.)
- [ ] `msg_id = BLAKE2s-128(sender ‖ created_at_le ‖ payload)` on both platforms;
      duplicate-content submissions collapse in dedup.
- [ ] PoW nonce inside the sealed payload; `HAS_POW` wired; both platforms
      verify.
- [ ] bloom = `BLAKE2s-64(msg_id ‖ uint32_be(round)) mod 4096`, 20B, 4 rounds,
      matches golden vectors on both platforms.
- [ ] `MessageStore` schema v2 (16B BLOB msg_id, receipt-monotonic retention,
      persist-before-forward, hard-cap, panic wipe) — ADR-004 exit criteria
      1,3,4,5,6 where repo-controlled.
- [ ] Noise prologue `"GMP2"` on both platforms; `crypto/handshake_vectors.json`
      regenerated; Invariant D re-pinned in the same patch.
- [ ] `scripts/verify_android_phase0.sh` PASS both modes with the GMP/2.1
      runtime; supplemental CI green.

**Status (patches 14–16, 20, 21 applied, execution-verified):** criteria 1, 2, 3
are green by execution (ticked). The remaining criteria are not yet
execution-closed: 4 (msg_id) / 5 (PoW `HAS_POW`) / 6 (bloom) / 7 (MessageStore
schema v2) are implemented in the Android `:mesh` runtime by patch 16 but need
their own executed unit tests cited before ticking; 8 is **blocked** — the
GMP2 prologue is on both platforms and executed (patches 20 + 21), but
Invariant D is **UNPINNED** (A-06 OPEN: no approved external Noise fixture), so
the "Invariant D re-pinned" half is not met; 9 — the runner PASSes both modes
(offline + online, `evidence/phase0-gmp21-{offline,online}`), but "supplemental
CI green" is not fully met because `check_parity.py` reports C/D/E FAIL
(pre-existing: C needs the archive build, D is A-06, E is tier-table drift).
A-01 therefore stays at IMPLEMENTED_LOCAL_VERIFIED for criteria 1–3 only and is
**not yet** the full §3 set — see the §4 closure rule. Verdict:
**PARTIALLY REMEDIATED — NOT READY.**

## 4. A-01 closure rule (§20)

**A-01 (`docs/AUDIT.md`: "Android and iOS mesh runtimes do not share a canonical
frame path") advances as follows:**

- **OPEN → IMPLEMENTED_LOCAL_VERIFIED:** when every repo-controlled acceptance
  criterion in §3 above is green by execution. At this point the two runtimes
  share the canonical GMP/2.1 frame path, message-id scheme, bloom rounds, and
  store schema, and both reproduce the golden vectors locally. This is the
  furthest A-01 can advance on repo-controlled evidence alone.
- **A-01 stays short of CLOSED** until **real Android↔iOS device interop
  evidence** exists: an encrypted frame generated on one platform, carried over
  the real BLE/Wi-Fi Aware link layer, parsed and authenticated on the other,
  with the anti-entropy digest agreeing on the held set. That requires device
  hardware and is an external/device gate, not repo-controlled. A-01
  **cannot** be closed by unit tests or golden-vector reproduction alone — those
  prove the runtimes agree with the spec and with each other in vitro, not that
  they interoperate over the air.

This rule is the same shape as the standing constraint that the overall verdict
stays "PARTIALLY REMEDIATED — NOT READY" until external/device gates have
evidence. A-01 IMPLEMENTED_LOCAL_VERIFIED is a repo-controlled milestone, not a
close.

## 5. External gates that remain OPEN (not in Stage 2 scope)

- **A-06 / Invariant D** — independent Noise conformance requires an approved
  **external** cacophony vector file (`crypto/cacophony_vectors.json`); Android
  and iOS agreeing with each other is not conformance. A-06 stays OPEN until an
  independent fixture is pinned and reviewed (`docs/PINNING_CACOPHONY.md`).
- **Invariant C** — `dist/archive_medium.db` (the model archive) is blocked by
  the llama.cpp / model-binary constraint on the shipping critical path; out of
  scope for the wire runtime.
- **Invariant E** — cross-platform tier-table disagreement; separate finding.
- **ADR-007** — cipher-suite SHA-256 change; OPEN, deferred (§2.3).
- **ADR-003/005/006** — identity/sealed-sender, SOS lifecycle, bulk plane;
  OPEN, separate workstreams.

## 6. Non-goals

- No migration of v1 store rows (ADR-001 §5: there is no installed base; V3
  never shipped on either platform).
- No enabling of Mesh/SOS/bulk on the LIGHT shipping path.
- No cipher-suite change (ADR-007, deferred).
- No device interop evidence (external gate; A-01 stays short of CLOSED).