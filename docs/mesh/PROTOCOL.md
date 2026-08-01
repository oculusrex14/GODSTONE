# Godstone Mesh Protocol — GMP/2.1 design contract

**Decision:** GMP/2.1 (`docs/adr/ADR-001-canonical-wire.md`)  
**Link design:** `docs/adr/ADR-002-ble-record-layer.md`  
**Implementation status:** **disabled and incomplete in V4**

This document is the target contract for the mesh. It is not a conformance
claim. Android still contains a disabled legacy router/store path; the BLE record
layer, deterministic handshake driver, durable iOS store, sealed-sender identity
binding, authenticated SOS lifecycle and bulk plane remain open. Both apps keep
the mesh feature flag false until the relevant acceptance tests pass.

Accepted ADRs override this summary if they disagree.

## 1. Layering

```
L5 APPLICATION   text, SOS, future media/archive exchange
L4 END TO END    sealed sender and authenticated application envelope
L3 ROUTING       delay-tolerant store-and-forward, DIGEST/WANT anti-entropy
L2 SESSION       Noise_XX_25519_ChaChaPoly_BLAKE2s
L1 RECORD        bounded BLE record fragmentation and reassembly
L0 TRANSPORT     BLE GATT control plane; bulk plane remains undecided
```

No application frame may be transmitted before the Noise session reaches
`READY`. There is no plaintext fallback.

## 2. Identity

Each install has distinct long-term keys:

- Ed25519 signing identity;
- X25519 static Noise key;
- `node_id = BLAKE2s-128(identity_signing_public_key)`.

The private keys never appear in frames. TOFU/QR verification, key-change
quarantine and panic wipe remain governed by ADR-003 and ADR-004; they are not
closed by V4.

## 3. BLE discovery target

The service UUID and characteristics come only from `wire/wire_v2.yaml`.

A legacy BLE advertisement cannot carry a 128-bit UUID plus the old 26-byte
service-data payload. ADR-002 therefore accepts:

- primary advertisement: service UUID only;
- scan response: 13-byte service data;
- active scan;
- first sightings without scan-response data are retained briefly rather than
  rejected.

Scan-response payload:

```
off size field
0   1    protocol version, 0x02
1   1    flags
2   4    node hint
6   6    short bloom digest
12  1    queue depth, saturating
```

The exact packet sizes must be verified on Android and iOS hardware before the
radio feature flag can be enabled.

## 4. BLE record layer

Handshake and data records use the accepted eight-byte record header from
ADR-002. Records are encrypted first and fragmented second. Bounds:

- maximum reassembled record: 16,384 bytes;
- maximum fragments: 64;
- maximum concurrent records per peer: 4;
- reassembly timeout: 30 seconds.

Malformed, duplicate, expired and allocation-exceeding fragments are rejected
before application parsing and charged to the peer abuse budget.

## 5. Noise session

Pattern: `Noise_XX_25519_ChaChaPoly_BLAKE2s`.

```
-> e
<- e, ee, s, es
-> s, se
```

The canonical prologue after M1-wire is:

```
"GMP2" || initiator_node_hint || responder_node_hint
```

Role election is deterministic: the lexicographically smaller node hint
initiates. A hint collision is resolved only after full identity is available;
an identical full node ID is a cloned-identity security event.

Session rekeying, TOFU pin enforcement and reconnect behavior require platform
port tests and the hardware matrix before being called conformant.

## 6. Canonical frame

All multi-byte fields are big-endian. The generated 32-byte header is:

```
off size field
0   2    magic          0x4753
2   1    version        0x02; minor capability 1 is negotiated in HELLO
3   1    type           generated even-parity type code
4   16   msg_id         BLAKE2s-128(sender || created_at || payload)
20  4    routing_tag    rotating recipient hint
24  1    ttl            maximum 16
25  1    hop_count      maximum 16
26  2    flags          feature flags + priority mask 0x0700
28  2    payload_len    maximum 60,000
30  2    header_crc     CRC-16/CCITT over bytes 0..29
```

Priority encoding uses three bits:

```
0 SOS   1 DIRECT   2 GROUP   3 BROADCAST   4 BULK
```

Generated codecs reject bad magic, version, type, CRC, lengths, TTL and hop
count before allocating the payload.

## 7. Time, retention and replay

There is no plaintext wall-clock timestamp in the frame header.

- retention uses the receiver's monotonic receipt time stored locally;
- an advisory sender `created_at` belongs inside the authenticated application
  envelope and may be omitted when the sender clock is untrusted;
- Noise nonces and the 16-byte message-ID seen cache suppress replay;
- receipt-relative expiry prevents a bad sender clock from discarding valid
  traffic or retaining it forever.

The Android legacy store does not yet implement this schema, so the radio remains
disabled.

## 8. Routing and anti-entropy

The target is bounded epidemic routing:

1. discover and elect roles;
2. complete Noise and TOFU checks;
3. exchange full 4096-bit bloom digests using the canonical hash input
   `msg_id[16] || uint32_be(round)` for four rounds;
4. exchange WANT lists;
5. send in strict priority order;
6. persist before forwarding;
7. decrement TTL and increment hop count without overflow;
8. never send a frame back to the peer it arrived from.

A digest describes **held durable frames**, not merely recently seen IDs. iOS
has no durable mesh store yet, so anti-entropy is not implemented end to end.

## 9. End-to-end envelope and anti-abuse

The threat-model goals require:

- sender and content sealed from relays;
- rotating routing tags;
- signed application envelopes;
- bounded parsing and storage;
- per-peer/per-priority token buckets;
- trust scoring and exponential refusal windows;
- a proof-of-work design whose nonce placement remains verifiable by relays
  without breaking sealed-sender privacy.

The last item is still unresolved between ADR-001 and ADR-003. It must be settled
before GROUP/BROADCAST traffic is enabled. V4 therefore does not claim the
sealed-sender or anti-abuse design is complete merely because helper classes
exist.

## 10. SOS truth states

UI wording is governed by ADR-005:

- `QUEUED_LOCAL` — durable local storage only;
- `HANDED_TO_RELAY(n)` — bytes accepted by authenticated transport peers;
- `ACKNOWLEDGED_BY_RECIPIENT` — valid end-to-end receipt;
- `FAILED` or `UNAVAILABLE`.

`SENT` or `DELIVERED` is forbidden before a valid recipient ACK. V4 disables SOS
mesh transmission rather than presenting a false success state.

## 11. Conformance gates

A platform may be called GMP/2.1 conformant only when all of these are green:

- generated codec parity and golden vectors;
- both routers and stores use the generated frame and 16-byte IDs;
- no legacy v1 symbol survives;
- platform Noise ports reproduce pinned external vectors;
- record-layer property tests cover every fragmentation boundary, reorder,
  duplicate, drop, timeout and allocation bound;
- two-device Android↔Android, iOS↔iOS and Android↔iOS encrypted ping tests;
- radio capture shows no plaintext frame;
- durable anti-entropy and panic-wipe tests;
- TOFU key-change quarantine;
- authenticated SOS lifecycle test through recipient ACK.

Until then the product must say **mesh unavailable**, not merely “degraded.”
