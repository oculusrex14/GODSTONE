# ADR-001 — Canonical runtime message model and GMP version

**STATUS: ACCEPTED** (31 Jul 2026)
Supersedes the OPEN placeholder in V4-draft. Implementation is tracked as
`M1-wire` and is NOT part of V4.

---

## 1. The decision

**GMP/2.1 is the canonical runtime format on both platforms.** It is GMP/2 with
four corrections, each forced by a defect found while writing this ADR.

GMP/1 is **deleted**, not migrated. See §5.

---

## 2. Why v2 and not v1

Three candidate directions were considered.

| Option | Verdict |
|---|---|
| Bring iOS back to GMP/1 | **Rejected.** The two v1 implementations were never byte-compatible with each other (20 vs 26-byte header, 8 vs 16-byte msg_id, SOS 0x08 vs 0x02, timestamp present vs absent). "Revert to v1" is not a revert; it is a fresh unification with none of v2's benefits. |
| Design GMP/3 | **Rejected.** v2 is already generated identically into both trees from `wire_v2.yaml`, has a magic, a version byte, a header CRC and even-parity type codes. Discarding that to start again is cost with no return. |
| **GMP/2 with corrections** | **Accepted.** Smallest change that yields one byte layout, and the codegen contract (Invariant A) is already the enforcement lever. |

---

## 3. The four corrections

### 3.1 Priority cannot fit in the flags mask — **arithmetic defect**

```
PRIORITY_MASK 0x00C0 = 0b11000000 = 2 bits = 4 distinct values
Android Priority     = SOS, DIRECT, GROUP, BROADCAST, BULK = 5 values
```

**GMP/2 cannot represent Android's existing priority set.** Nobody noticed
because no Android code path ever constructed a `FrameV2`. A mechanical type
swap would have silently collapsed two priority classes into one — and the class
most likely to collide is the one that decides what gets dropped under flood.

**Decision.** Promote priority to an explicit 3-bit field carved from the flags
word, `PRIORITY_MASK = 0x0700` (bits 8–10, 8 values). The old 0x00C0 bits are
returned to the reserved pool. Encoding is fixed and shared:

```
0 SOS   1 DIRECT   2 GROUP   3 BROADCAST   4 BULK   5-7 reserved
```

`wire/codegen.py` gains an assertion that `popcount(PRIORITY_MASK) >= ceil(log2(len(priority)))`,
so this class of defect fails the build rather than the mesh.

### 3.2 No plaintext timestamp — **and no timestamp in the header at all**

GPT's review challenged the assumption directly: *"Determine whether timestamps
belong inside a sealed/authenticated envelope, how devices without accurate
clocks expire messages, and how replay/retention work across clock rollback."*

Taking that seriously changes the answer. A header timestamp is:

- **a fingerprinting surface** — a plaintext wall-clock value visible to every
  relay is a strong correlator, which directly undermines the A7 claim that
  daily-rotating routing tags defeat traffic analysis;
- **unreliable exactly when it matters** — in a blackout, devices reboot without
  network time. Android's `MAX_AGE_SECONDS` compares a sender's wall clock to
  the receiver's. Two devices days apart discard each other's valid traffic;
- **not needed for retention** — what a node must know is *how long has this
  frame been in MY store*, which is a local monotonic question.

**Decision — three separate clocks, never conflated:**

| Purpose | Source | Where it lives |
|---|---|---|
| retention / expiry | receiver's **monotonic** clock at receipt | store column, never on the wire |
| sender's claim of creation time | `created_at` uint32 epoch-seconds | **inside the sealed, signed payload** |
| token buckets, session timeouts | monotonic elapsed | memory only |

The header carries **no timestamp**. Retention is receipt-relative: a frame is
held `min(RETENTION[priority], MAX_HOLD)` from *local receipt*, so an SOS carried
by a phone with a broken clock still expires correctly on every relay.
`created_at` is advisory, authenticated, and used only for display and for
ordering within a single sender.

A device whose clock is untrusted (no time source since boot) sets a
`CLOCK_UNTRUSTED` flag and omits `created_at` rather than asserting a wrong one.

### 3.3 Message id derivation

`PROTOCOL.md` says ids are content-derived; Android uses a random `Long`, iOS 16
random bytes. Neither matches, and a random id lets one sender flood distinct ids
for identical content.

**Decision.** `msg_id = BLAKE2s-128(sender_node_id ‖ created_at_le ‖ payload)`,
16 bytes. Content-derived means duplicate submissions collapse in the dedup
cache. Proof-of-work still searches a nonce, but the nonce moves into the sealed
payload rather than being the id itself — V3's `ProofOfWork.mine` mutated
`msg_id`, which is fine when the id is random and **breaks the moment the id is a
content hash**.

### 3.4 Bloom digest hash input

iOS hashes `Data(16) ‖ UInt8(round)` = 17 bytes; Android hashes
`Long(8) ‖ Int(4)` = 12 bytes. Different widths, different round encoding,
different bits.

**Decision.** `index = BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096`,
20 bytes hashed, 4 rounds. Golden vectors are generated by `wire/codegen.py` and
both platforms must reproduce them.

---

## 4. The canonical header

32 bytes, big-endian, unchanged in size from GMP/2:

```
off  size  field
0    2     magic          0x4753
2    1     version        0x02   (minor 1 signalled in HELLO capabilities)
3    1     type           even-parity code, >= 2 Hamming from every other
4    16    msg_id         BLAKE2s-128(sender ‖ created_at ‖ payload)
20   4     routing_tag    BLAKE2s-32(recipient_node_id ‖ epoch_day)
24   1     ttl            initial 12, max 16
25   1     hop_count      increments on relay
26   2     flags          PRIORITY_MASK 0x0700 (3 bits) + feature bits
28   2     payload_len    max 60000
30   2     header_crc     CRC-16/CCITT over bytes 0..29
```

Everything else — `created_at`, PoW nonce, sender id, signature — lives inside
the sealed payload, where it is authenticated rather than merely present.

---

## 5. Migration: there is nothing to migrate

The obvious hard problem is converting `msg_id INTEGER PRIMARY KEY` rows to a
16-byte BLOB, and deriving 16-byte ids from 8-byte ones (impossible without the
original content).

**It does not arise. V3 has never compiled on either platform.** There is no
installed base, no user device holding v1 rows, and no field data. Both reviews
treated store migration as a blocker; it is an artefact of assuming the software
exists in the world.

**Decision.** Delete `android/mesh/.../wire/Frame.kt` and
`ios/.../GodstoneMesh/Frame.swift`. Create the store fresh at schema v2. Write
**no** migration code. Add a build assertion that no v1 symbol survives.

If a build ever *does* ship before this lands, this decision is void and a real
migration is required — recorded here so the reasoning is auditable rather than
rediscovered.

---

## 6. v1 rejection policy

A v1 frame has `version == 0x01` at offset 2 where v2 has magic. It fails the
magic check first and is dropped. **Never best-effort parsed.** V4's renumbering
already ensures no v2 type code falls in v1's 0x01–0x0A range, so a stray legacy
frame reaches the unknown-type branch instead of arriving as an SOS.

---

## 7. Noise prologue version binding

Both platforms bind `"GMP1"` into the Noise prologue while advertising GMP/2.
Since both are wrong identically, it currently "works" — the exact
self-consistent-but-wrong failure the interop matrix exists to expose.

**Decision.** `prologue = "GMP2" ‖ initiator_hint ‖ responder_hint`. Changing
this invalidates every pinned vector, so `crypto/gen_vectors.py` must regenerate
and Invariant D must be re-pinned **in the same commit** as the wire change.

---

## 8. Acceptance criteria

An implementation satisfies ADR-001 when:

- [ ] one normative `wire_v2.yaml`; both codecs generated, Invariant A green
- [ ] `codegen.py` asserts the priority mask is wide enough for the priority set
- [ ] cross-platform golden vectors for every type, both bloom rounds, and edge
      values (ttl 0/16, payload 0/60000, all priorities)
- [ ] both routers operate on the canonical type; no v1 symbol resolves
- [ ] `created_at` and the PoW nonce are inside the authenticated payload
- [ ] retention is receipt-relative; a frame from a device 10 days out of sync
      is neither dropped early nor held forever
- [ ] Invariant D re-pinned against the `GMP2` prologue

Until every box is ticked, `ci/integration.py` Invariant H continues to fail any
documentation claiming cross-platform interoperability.
