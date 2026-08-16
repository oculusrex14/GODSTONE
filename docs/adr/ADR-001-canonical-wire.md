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

### 3.3 Logical message identity and msg_id derivation (C6.7)

#### 3.3.1 The collision defect in pure content-hash identity

`PROTOCOL.md` previously specified `msg_id = BLAKE2s-128(sender_node_id ‖ created_at_le ‖ payload)`.
While deterministic content hashing was intended to collapse identical submissions in dedup caches,
content equality is fundamentally **not** identical to logical send intent. This created critical
identity collision defects:

1. **Multi-recipient collision (Alice vs Bob):** If sender $S$ authors a message ("meet at clinic")
   and sends it independently to Alice and Bob in the same second $T$, both messages receive the exact
   same `msg_id`. In `delivery_state`, `PRIMARY KEY = msg_id` with an immutable `expected_recipient`.
   A single `msg_id` cannot represent both Alice and Bob delivery tracks, causing the second enqueue
   to be rejected or corrupt the expected recipient.
2. **Repeated send collision:** If sender $S$ sends "yes" to Alice twice in the same second $T$, both
   logical sends collapse into the same `msg_id`, causing the second message to be dropped as a duplicate.
3. **Retries vs distinct sends:** A transmission retry of an *existing* message must preserve its
   `msg_id` so relays and recipient deduplicate it; but two separately created logical messages must
   receive distinct identities even when sender, content, and timestamp coincide.

#### 3.3.2 Design options evaluated

- **Option A (Include recipient in hash):** `BLAKE2s-128(sender ‖ recipient ‖ created_at_le ‖ payload)`.
  *Rejected.* Does not solve same-recipient same-second repeats; tightly couples message identity to
  transport addressing; breaks multi-recipient forwarding, broadcast re-addressing, and leaks routing
  context into the message identity layer.
- **Option B (Accepted — Sender-generated per-logical-message nonce):**
  When a node creates a new logical message, it generates a 16-byte cryptographic random nonce
  (`message_nonce` via CSPRNG). Retries reuse the same `message_nonce` and `msg_id`; newly authored
  sends generate a fresh `message_nonce`.

#### 3.3.3 Canonical `msg_id` preimage and domain separation

`msg_id` is derived using BLAKE2s-128 with domain separator `b"GMP2-MSGID"` (10 ASCII bytes):

```text
preimage = ASCII("GMP2-MSGID") ‖ sender_node_id[16] ‖ uint32_le(created_at) ‖ message_nonce[16] ‖ plaintext
msg_id   = BLAKE2s-128(preimage)   (16 bytes)
```

- `MSG_ID_DOMAIN`: `b"GMP2-MSGID"` (10 bytes: `0x47, 0x4d, 0x50, 0x32, 0x2d, 0x4d, 0x53, 0x47, 0x49, 0x44`)
- `sender_node_id`: 16 bytes
- `created_at`: uint32 little-endian epoch seconds (4 bytes)
- `message_nonce`: 16 bytes (CSPRNG generated once at creation)
- `plaintext`: variable-length unsealed application payload bytes

#### 3.3.4 Canonical sealed inner layout & recipient rederivation

To allow the recipient to authenticate the logical identity upon unsealing, `message_nonce` is placed
inside the authenticated sealed envelope:

```text
sealed_inner = message_nonce[16] ‖ pow_nonce[8] ‖ created_at_le[4] ‖ plaintext
```

Fixed prefix length = $16 + 8 + 4 = 28$ bytes.

**Recipient verification:** Upon unsealing with `SealedSender.open`, the recipient extracts
`message_nonce`, `pow_nonce`, `created_at_le`, and `plaintext`. The recipient then computes
`MessageId.derive(sender_node_id, created_at, message_nonce, plaintext)` and asserts that the derived
ID matches the 16-byte `frame.msg_id` in the header. If it mismatches, the frame is rejected.

#### 3.3.5 Abuse and flood resistance separation

`msg_id` is an **identity primitive**, not an abuse-control primitive. Flood resistance is enforced
orthogonally by `PeerGovernor` token buckets, connection rate limits, bounded durable storage caps,
and Proof-of-Work (`HAS_POW`) on applicable priorities (GROUP / BROADCAST).

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
4    16    msg_id         BLAKE2s-128(b"GMP2-MSGID" ‖ sender ‖ created_at_le ‖ message_nonce ‖ plaintext)
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
