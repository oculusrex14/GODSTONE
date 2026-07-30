# Godstone Mesh Protocol (GMP/1)

Version: 1.0
Status: normative
Applies to: Android and iOS clients, protocol version byte 0x01

## 0. Design rationale

Godstone Mesh moves messages between phones with no infrastructure of any kind.
No servers, no SIM, no towers, no internet. It is designed for the hours and days
after infrastructure fails, when the only network left is the one people carry.

Three transport strategies were evaluated:

| Option | Verdict |
|---|---|
| BLE only | **Rejected.** 1–10 kbps cannot move a voice note or an image. Content sharing, a core feature, dies. |
| Third-party SDK (Bridgefy, Google Nearby) | **Rejected.** Bridgefy's protocol was broken publicly (Albrecht et al., 2020) with practical impersonation and decryption attacks; Google Nearby is closed source, depends on Play Services and does not exist on iOS. A life-safety application cannot delegate its crypto to an unauditable third party. |
| **Hybrid BLE control plane + Wi-Fi bulk plane, Noise-based crypto** | **Chosen.** Gets always-on low-power presence from BLE and high throughput from Wi-Fi, with auditable, composed cryptography. |

The cost of the chosen option is complexity: two transports and a session layer to
maintain. That cost is accepted because the alternative is an app that either
cannot carry real content or cannot be trusted with a life.

## 1. Layering

    +-------------------------------------------------------------+
    | L5 APPLICATION   text, voice note, image, SOS, archive chunk |
    +-------------------------------------------------------------+
    | L4 SEALED SENDER end-to-end encryption, sender anonymity     |
    +-------------------------------------------------------------+
    | L3 ROUTING       DTN store-and-forward, bloom digest sync    |
    +-------------------------------------------------------------+
    | L2 SESSION       Noise_XX_25519_ChaChaPoly_BLAKE2s per link  |
    +-------------------------------------------------------------+
    | L1 TRANSPORT     BLE GATT (control)  |  Wi-Fi (bulk)         |
    +-------------------------------------------------------------+

Each layer is independently testable. L3 and above are transport agnostic and run
unchanged in the simulator (see tab 12_TESTS_CI).

## 2. Identity

Every install generates, on first launch, inside the platform secure element where
available:

    identity_key    Ed25519 keypair    long-term, signs and authenticates
    static_dh_key   X25519 keypair     long-term, Noise static key
    node_id         BLAKE2s-128(identity_pub)   16 bytes, the node address

The user-visible "call sign" is a 6-word mnemonic derived from node_id, so two
people can verify each other verbally. Out-of-band verification is by QR code
containing identity_pub, which marks the contact verified locally.

Private keys never leave the device and are never transmitted in any frame.

Panic wipe erases identity_key, static_dh_key, all sessions and the message store,
and regenerates a fresh identity, making prior traffic unlinkable to the new node.

## 3. Transport layer (L1)

### 3.1 BLE control plane

Service UUID:            6764-0001-1000-8000-00805f9b34fb
Characteristic (write):  6764-0002-...   peer -> us, 512 byte MTU target
Characteristic (notify): 6764-0003-...   us -> peer

Advertisement payload, 26 bytes in the service data field:

    offset  size  field
    0       1     protocol_version         0x01
    1       1     flags                    bit0 SOS_PRESENT
                                           bit1 BULK_CAPABLE
                                           bit2 POWER_CONSTRAINED
                                           bit3 VERIFIED_ONLY
    2       4     node_hint                first 4 bytes of node_id
    6       16    bloom_digest_short       truncated bloom of held message ids
    22      2     queue_depth              held messages, saturating
    24      2     epoch                    minutes since boot, wraps

A peer decides whether to connect purely from the advertisement. If the bloom
digest indicates it holds nothing we lack and we hold nothing it lacks, no
connection is made. This is the single most important power optimisation in the
system: most encounters cost one advertisement scan and nothing more.

Duty cycle by power state:

    state            advertise interval   scan window / interval
    NORMAL           1000 ms              300 ms / 2000 ms
    POWER_SAVE       3000 ms              300 ms / 8000 ms
    CRITICAL (<15%)  10000 ms             300 ms / 30000 ms
    SOS_ACTIVE       200 ms               continuous

### 3.2 Wi-Fi bulk plane

Brought up only when a transfer exceeds BULK_THRESHOLD (512 bytes) and both peers
advertise BULK_CAPABLE. Negotiated over the established BLE session, so the Wi-Fi
link inherits an already-authenticated Noise session and needs no second handshake.

    Android: Wi-Fi Aware (NAN), API 26+. Falls back to Wi-Fi Direct, then to BLE.
    iOS:     MultipeerConnectivity, peer-to-peer Wi-Fi, encrypted session required.

The bulk link is torn down within 5 seconds of the last byte. It is never left up.

### 3.3 iOS background limitations (normative, must be surfaced in UI)

In the background iOS restricts BLE advertising to the "overflow" area, service
UUIDs are not visible to non-iOS scanners, and MultipeerConnectivity does not run
at all. Consequences that MUST be communicated to the user:

    * iOS-to-iOS background discovery works but is slower and less reliable.
    * iOS-to-Android background discovery is unreliable; foreground fixes it.
    * Bulk transfer requires the app to be foregrounded on the iOS side.

The UI therefore shows a persistent, honest "mesh strength" indicator and, during
an active emergency, asks the user to keep the app open. Pretending this
limitation does not exist would be the dangerous choice.

## 4. Session layer (L2) — Noise

Pattern: **Noise_XX_25519_ChaChaPoly_BLAKE2s**

XX is chosen because neither party knows the other's static key in advance (any
stranger may be a relay), it provides mutual authentication, and it gives identity
hiding for the responder.

    -> e
    <- e, ee, s, es
    -> s, se

Prologue binds the handshake to the protocol version and both advertised node
hints, preventing cross-protocol and downgrade attacks:

    prologue = "GMP1" || initiator_node_hint || responder_node_hint

After the handshake each direction has its own ChaCha20-Poly1305 cipher state with
a 64-bit nonce counter. A session rekeys after 2^20 messages or 30 minutes,
whichever comes first. Sessions are cached per peer for 24 hours and survive
transport switching from BLE to Wi-Fi.

Static keys are pinned on first contact (TOFU). A changed static key for a known
node_id raises a visible warning and marks the contact unverified. It does not
silently accept.

## 5. Frame format (L2/L3)

All multi-byte integers are big-endian. Every frame is carried inside a Noise
transport message, so the fields below are the plaintext seen after decryption.

    offset  size  field
    0       1     version          0x01
    1       1     type             see 5.1
    2       2     length           payload length, max 65535
    4       1     ttl              remaining hops, initial 12, max 16
    5       1     priority         0 SOS, 1 DIRECT, 2 GROUP, 3 BROADCAST, 4 BULK
    6       8     msg_id           BLAKE2s-64 of (payload || sender || timestamp)
    14      6     timestamp        unix seconds, truncated
    20      N     payload

### 5.1 Frame types

    0x01 HELLO           capability and version exchange, post-handshake
    0x02 DIGEST          bloom filter of held msg_ids
    0x03 WANT            explicit request for listed msg_ids
    0x04 MESSAGE         a sealed application message
    0x05 ACK             end-to-end delivery receipt, itself sealed
    0x06 BULK_OFFER      announce a large payload, negotiate Wi-Fi
    0x07 BULK_CHUNK      one chunk of a bulk transfer
    0x08 SOS             priority emergency broadcast
    0x09 PING            liveness and RTT probe
    0x0A GOODBYE         graceful session teardown

## 6. Sealed sender (L4)

Relays must learn nothing beyond "a message exists and needs forwarding". The
MESSAGE payload is therefore encrypted twice.

    inner  = ChaCha20-Poly1305( K_e2e, plaintext )
             K_e2e derived from X3DH-style agreement between sender static and
             recipient static keys, with an ephemeral for forward secrecy
    sealed = ephemeral_pub || ChaCha20-Poly1305( K_seal, sender_id || inner )
             K_seal = HKDF(X25519(ephemeral_priv, recipient_static_pub))

A relay sees only: ephemeral_pub, ciphertext, and a 4-byte **routing tag**:

    routing_tag = BLAKE2s-32(recipient_node_id || epoch_day)

The tag rotates daily, so long-term traffic analysis by tag is defeated, while a
recipient can still cheaply recognise messages that may be theirs. Tag collisions
are expected and harmless: a device attempts decryption of matching messages and
discards failures. Roughly 1 in 4 billion false positives per message is a
negligible decryption cost and a real privacy gain.

## 7. Routing (L3) — delay-tolerant store and forward

There is no routing table. In a disaster the topology changes faster than any
table converges; assuming otherwise is the standard failure of mesh messengers.
Godstone uses **epidemic routing with bloom-filter digest exchange**, bounded by
TTL, priority and storage.

Encounter procedure:

    1. Read peer advertisement, compare short bloom digest.
    2. If potential novelty on either side, connect and complete Noise handshake.
    3. Exchange full DIGEST frames (4096-bit bloom, 4 hashes, ~0.9% FP at 2000 msgs).
    4. Each side computes what the other appears to lack, sends WANT for gaps.
    5. Transfer in strict priority order: SOS, then DIRECT, then GROUP, BROADCAST.
    6. Payloads over 512 bytes negotiate the Wi-Fi bulk plane via BULK_OFFER.
    7. Decrement TTL on forward, drop at zero, record msg_id in the seen-cache.

Forwarding rules:

    * Never forward a msg_id already in the seen-cache (16k entry LRU).
    * Never forward back to the peer it was received from.
    * Drop TTL 0, drop timestamps more than 14 days old, drop malformed frames.
    * SOS gets TTL 16, extended 30-day retention and is evicted last.
    * A message addressed to us is decrypted, stored, and still relayed once more
      to help it reach other recipients in a group.

Storage budget and eviction, default 200 MB:

    evict order: expired -> BROADCAST oldest -> GROUP oldest -> BULK cache
                 -> DIRECT oldest -> SOS oldest (last resort only)

## 8. Anti-abuse

An open mesh where anyone can inject anything is a battery-drain weapon. Controls:

    * **Proof of work** on BROADCAST and GROUP frames: 20-bit BLAKE2s partial
      preimage over msg_id. Costs a sender ~200 ms, costs a flooder everything.
      SOS and DIRECT frames are exempt, since latency there is a safety property.
    * **Rate limits** per peer per priority class, token bucket, enforced at the
      session layer before any parsing of application payload.
    * **Local trust score** per node_id: increments on well-formed useful traffic,
      decrements on malformed frames, failed MACs and duplicate floods. Low scores
      are throttled, then refused connection for an exponentially growing window.
    * **Bounded parsing**: every length field is validated against the remaining
      buffer before allocation. No allocation is driven by an attacker-supplied
      length without a hard cap.
    * **Replay defence**: msg_id seen-cache plus a per-session monotonic nonce.
      A replayed frame fails the Noise nonce check before it reaches routing.

## 9. Versioning

The version byte is checked before any other parsing. Unknown major versions are
refused with GOODBYE rather than best-effort parsed. Capability negotiation in
HELLO carries a feature bitmap so that additive features do not require a version
bump, and so a v1 node and a future v2 node degrade to the v1 intersection instead
of failing to communicate. In an emergency, interoperability is a safety property.

## 10. Conformance checklist

An implementation is GMP/1 conformant if:

    [ ] Refuses any frame whose version byte is not 0x01
    [ ] Completes Noise_XX with the specified prologue and rejects mismatches
    [ ] Pins static keys TOFU and warns visibly on change
    [ ] Enforces TTL decrement and drops at zero
    [ ] Maintains a seen-cache of at least 16384 msg_ids
    [ ] Validates every length field against the remaining buffer
    [ ] Enforces proof of work on BROADCAST and GROUP, exempts SOS and DIRECT
    [ ] Evicts SOS last under storage pressure
    [ ] Rotates routing tags daily
    [ ] Never logs plaintext, keys or peer identifiers to persistent storage
