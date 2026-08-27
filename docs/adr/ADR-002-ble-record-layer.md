# ADR-002 — BLE roles, record framing, and the Noise handshake driver

**STATUS: ACCEPTED / PHASE C8.4C RECORD LAYER IMPLEMENTED & FROZEN** (27 Aug 2026)
Implementation: Phase C8.4C canonical BLE record layer (types, balanced-stride codec, fragmenter, bounded reassembler with injected clock, duplicate suppression, conflict rejection, encrypt-then-fragment semantic verification, 32/229/197 handshake composition tests, independent Python reference wire/ble_record_reference.py, and locked vectors wire/ble_record_vectors.json) is implemented and verified. Full link enablement (radio/GATT drivers) remains open behind LINK_LAYER_READY=false / linkLayerReady=false.

---

## 1. The decision, in one line

**A four-field record layer outside the encrypted frame; encrypt-then-fragment;
deterministic role election by node_id; and a 13-byte advertisement in the scan
response**, because the 26-byte one is physically impossible.

---

## 2. The advertisement does not fit — **measured, not assumed**

GPT's review asked the right question: *"Check Android advertisement-size limits
with the 128-bit UUID plus 26 bytes of service data."* The arithmetic:

```
BLE legacy advertisement budget                       31 bytes
  AD: complete 128-bit UUID list   = 1+1+16         = 18 bytes
  AD: service data (128-bit UUID) + 26-byte payload
                                   = 1+1+16+26      = 44 bytes
  both in one packet                                = 62 bytes   DOES NOT FIT
```

`PROTOCOL.md` §3.1 specifies a 26-byte service-data payload alongside a 128-bit
service UUID. **That has never been transmittable.** Android's
`startAdvertising` would have failed with `ADVERTISE_FAILED_DATA_TOO_LARGE` the
first time anyone called `addServiceData` — which is precisely why the bug hid:
`buildAdvertisementPayload()` had no caller, so the impossible packet was never
constructed. The scanner's `if (sd.size < 26) return` was rejecting a payload the
advertiser could not have sent.

### Decision

Split across advertisement and scan response, and shrink the payload to 13 bytes:

```
ADVERTISEMENT   (31 B budget)
  complete 128-bit service UUID                        18 B   -> 13 B spare

SCAN RESPONSE   (31 B budget)
  service data, 128-bit UUID + 13-byte payload    2+16+13 = 31 B   -> exact fit

  off size field
  0   1    protocol_version   0x02
  1   1    flags              bit0 SOS_PRESENT   bit1 BULK_CAPABLE
                              bit2 POWER_CONSTRAINED   bit3 VERIFIED_ONLY
                              bit4 CLOCK_UNTRUSTED (ADR-001 §3.2)
  2   4    node_hint          first 4 bytes of node_id
  6    6   bloom_digest_short truncated bloom of held msg_ids
  12   1   queue_depth        saturating, 0-255
```

`epoch` is dropped: it existed to detect staleness, which ADR-001 §3.2 now
handles with receipt-relative retention. The digest shrinks 16 → 6 bytes,
raising the false-positive rate on the *pre-connection* filter only. That is the
correct place to lose precision: a false positive costs one unnecessary
connection, and the full 4096-bit digest is exchanged after the handshake anyway.

**Scan response requires active scanning.** `CBCentralManager` scans actively by
default; Android must use `SCAN_MODE_*` with a `ScanFilter` on the service UUID.
Both platforms must handle a scan result arriving *without* service data (adv
seen, scan response not yet received) by waiting rather than rejecting — V3's
scanner returned immediately, which would have dropped every first sighting.

---

## 3. Role election

Two peers that both initiate produce two half-open handshakes; two that both wait
produce none. V3 had no election at all, and iOS unconditionally called
`beginInitiator` on `transportReady`.

**Decision — no negotiation round-trip, decide locally from data both sides
already have:**

```
initiator = the peer whose node_hint is lexicographically SMALLER
            (unsigned byte comparison, 4 bytes, from the advertisement)
tie (identical hints, ~1 in 2^32):
            compare full node_id after the handshake; if still equal, both
            abort and re-scan with jitter -- an identical node_id means a
            cloned identity, which is a security event, not a race
```

Both sides compute the same answer from the same bytes before any packet is
exchanged. The loser opens the GATT server and waits; the winner connects.

---

## 4. Encrypt-then-fragment

The question GPT posed: *"Decide whether to encrypt before fragmentation or
fragment before encryption. Compare memory, replay, integrity and
retransmission consequences."*

| | encrypt-then-fragment | fragment-then-encrypt |
|---|---|---|
| Noise nonce granularity | one per **record** — matches the spec as written | one per **fragment** — needs a new AAD construction binding index/count, invented here |
| integrity | all-or-nothing; a corrupted fragment fails the whole record | per-fragment, so partial plaintext can reach the reassembler |
| memory | bounded by MAX_RECORD | bounded by MAX_RECORD |
| retransmit cost | whole record | single fragment |
| new cryptography required | **none** | a specified per-fragment AEAD |

**Decision: encrypt-then-fragment.** The retransmission cost is real and
accepted — BLE records here are ≤ 16 KB and the DTN layer already re-offers on
the next encounter. The decisive factor is C6 (*compose crypto, never invent
it*): fragment-then-encrypt requires designing a per-fragment authenticated
construction, and this repository has already shipped three defects in
hand-rolled crypto.

All-or-nothing integrity is also the *safer* failure: a partially-decrypted frame
must never reach the router, and encrypt-then-fragment makes that structural
rather than a check someone has to remember.

---

## 5. The record layer

Outside the Noise ciphertext, because handshake messages must be carried before a
session exists. 8-byte header:

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
  REASSEMBLY_TIMEOUT 30 s   (bitchat field value; see 7b)
  MAX_CONCURRENT    4 records in flight per peer  -> 64 KB peak per peer
```

A fragment whose `frag_index >= frag_count`, whose `total_len > MAX_RECORD`, or
which arrives for an expired `record_seq`, is dropped and charged to the peer's
abuse budget. Reassembly buffers are allocated on the **first** fragment against
`total_len`, so `MAX_RECORD` is a hard allocation cap rather than an accumulating
one.

This directly fixes the V3 iOS defect: `send` fragmented a Noise ciphertext
across ATT writes while `didUpdateValueFor` handed **each inbound fragment** to
`sessions.open` as a complete message. Anything above one ATT write was
undecryptable by construction.

---

## 6. The handshake driver

The state machine that does not exist on either platform. V4 makes
`NoiseSession.swift` wire-conformant; it still has nothing to carry messages 1–3.

```
DISCOVERED --(elected initiator)--> CONNECTING --> DISCOVERING_SERVICES
    |                                                      |
    (elected responder)                                    v
    |                                              SEND HS1 -> AWAIT_HS2
    v                                                      |
LISTENING --(HS1 rx)--> SEND HS2 -> AWAIT_HS3              v
    |                                              rx HS2 -> SEND HS3 -> ESTABLISHED
    v                                                      |
rx HS3 -> ESTABLISHED                                       |
                                                            v
                              ESTABLISHED --> (TOFU pin check, ADR-003) --> READY
                                          --> pin mismatch --> QUARANTINE, no data

timeouts:  each AWAIT_* 5 s, then teardown + exponential backoff (1s, 2s, 4s ... 60s)
budgets:   3 handshake attempts per peer per 5 min (pre-auth, ADR-003 stage 2)
prologue:  hints from the REAL advertisement, never Data(repeating: 0, count: 4)
```

No application frame is accepted before `READY`. There is deliberately **no
plaintext fallback** at any state.

---

## 7. Android's dead receive path

`GattServer.incoming()` is a cold `callbackFlow`; it opens the GATT server only
when collected. `MeshNode.start()` collects `ble.peers()` and nothing else, so
the server is never opened, ciphertext is never decrypted, and the router never
receives a frame.

**Decision.** The radio lifecycle becomes a single owned scope, started in this
order: GATT server → inbound collector → **then** advertise. Advertising before
the server accepts connections is a race a peer can win.

---

## 7b. Independent corroboration from bitchat

Two of this ADR's decisions were reached by argument. A shipping cross-platform
BLE mesh reached the same conclusions in production.

**The advertisement.** bitchat's advertising data is **the service UUID and
nothing else** — documented as *"Advertising Data: Service UUID only — Maximizes
privacy — no local name broadcast."* No service-data payload at all. That is
independent confirmation of §2: the 26-byte payload does not fit beside a 128-bit
UUID, and a real implementation simply does not carry one.

bitchat pays for that with a connection on every encounter — it gives up the
pre-connection filter that `PROTOCOL.md` §3.1 calls *"the single most important
power optimisation in the system"*. **This ADR's 13-byte scan-response payload is
a middle path that bitchat did not take, and it is therefore unproven.** If it
fails on device, falling back to bitchat's UUID-only advertisement is a known-good
answer that costs battery, not correctness. Recorded so the fallback is a
decision rather than a scramble.

**Fragmentation order.** bitchat fragments *after* encryption — the complete
encoded message, post-compression and post-Noise, is what gets split when it
exceeds the negotiated MTU. That is encrypt-then-fragment, chosen here in §4 on
C6 grounds. Two independent derivations, same answer.

Their parameters, against this ADR's:

| | bitchat | ADR-002 |
|---|---|---|
| default fragment | 469 B | MTU-derived |
| fragment metadata | 13 B | 8 B |
| reassembly timeout | **30 s** | 10 s |
| max fragments | ~100 | 64 |
| per-peer streams | yes | yes |

**Adopt their 30-second timeout.** 10 s was chosen by feel; 30 s comes from a
year of field use on real radios, where a peer walking behind a wall mid-transfer
is routine. The other numbers are close enough that the convergence is itself
evidence.

**Also worth taking:** bitchat runs separate testnet and mainnet service UUIDs
(`…4B5A` / `…4B5C`). GODSTONE has one UUID, so any field test pollutes the
production mesh and vice versa. Cheap to add now, painful to retrofit once
devices are deployed.

## 8. Acceptance criteria

- [ ] property test: fragment every record at every boundary from 1 byte to the
      negotiated MTU, with reorder, drop, duplicate — exactly-once or clean failure
- [ ] advertisement + scan response verified ≤ 31 bytes each **on device**, not
      only in arithmetic
- [ ] role election test: 1000 random node_id pairs, exactly one initiator each
- [ ] Android↔Android and iOS↔iOS encrypted ping, radio bytes captured, **no
      plaintext GMP frame observable**
- [ ] repeated `start()` produces one scan, one server, one collector
- [ ] tamper, replay, reconnect, simultaneous-connect, and timeout paths recover

Hardware Case 0 (Android↔iOS) additionally requires ADR-001 implemented, since
the two platforms do not share a frame format until then.
