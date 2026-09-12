# ADR-005 — SOS authenticity, delivery semantics and capability lifecycle

**STATUS: OPEN.**

## V4 safety position

SOS transmission is disabled on both platforms while M1-wire/M2-link and this
ADR remain incomplete. The UI reports the reason and does not claim that a
message carries location, a call sign, or recipient delivery.

The required lifecycle is:

```text
UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
                                      \-> EXPIRED | CANCELLED_LOCALLY
```

A successful GATT write is only `HANDED_TO_RELAY`. `SENT` is forbidden unless an
authenticated intended recipient ACKs the exact message ID. Cancellation cannot
recall already relayed copies and must say so.

## Decisions still required

- minimum stranger-to-stranger authenticity model;
- signature transcript and how the verification key is obtained/bound;
- recipient/group addressing without exposing the social graph;
- ACK authentication, timeout, retry, duplicate and multi-recipient semantics;
- optional location acquisition, freshness and consent;
- permission/capability states: denied, permanently denied, revoked, Bluetooth
  off, unsupported radio, background restrictions and critical battery;
- accessible hold/confirm/cancel behavior under stress.

## Exit criteria

Truth-table tests for every state; reboot recovery; no unsigned SOS accepted;
tamper/replay rejected; no UI phrase stronger than its cryptographic evidence;
and Android↔iOS hardware tests with radios captured.

## Stage 3 Phase H — authenticated ACK state machine (repo-owned evidence; NOT closed)

The durable, recipient-authenticated delivery state machine and the
authenticated-ACK verification are now implemented and **repo-tested on both
platforms without a device or radio**. The radio/link layer remains disabled
(M2-link), so this is evidence for the state machine + cryptographic ACK
verification — not an on-device delivery proof. ADR-005 stays **OPEN**.

### Lifecycle (implemented)

```text
UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
                                      \-> EXPIRED | CANCELLED_LOCALLY
```

`DeliveryTracker` enforces the truth-table: every successful transition is
persisted to a `DeliveryJournal` **after** it is applied (crash-then-resume
re-reads the last persisted state); illegal transitions and a rejected ACK
return false and do not mutate state. Terminal states are acknowledged /
expired / cancelled; re-issuing the same terminal op is idempotent (a
crash-then-resume that re-issues `cancel`/`expire` still succeeds), while a
*different* op from a terminal state is rejected. A successful GATT write is
only `HANDED_TO_RELAY`; only `acknowledge` can reach `ACKNOWLEDGED_BY_RECIPIENT`.

### Minimum authenticity model (implemented)

The recipient signs the **exact** message id with their long-term Ed25519
identity signing key; the holder verifies against the recipient's public key,
bound to the recipient's node id by a `RecipientKeyResolver` (the Noise_XX
handshake / contact registry in production). The signature binds **both** the
message id and the recipient node id, so:

- an unsigned ACK is rejected (no signature to verify);
- a tampered signature / payload is rejected (Ed25519 verify fails);
- an ACK for message X cannot be replayed to ack message Y — the signed
  preimage includes the message id, so the signature is wrong for Y;
- an ACK claiming a different recipient is rejected — the preimage includes the
  recipient node id, and the resolver returns the public key for that node id,
  under which a signature made by another recipient does not verify.

ACK frame layout (byte-identical cross-platform): `type = ack (0x21)`,
`msgId = the exact message id (16)`, `routingTag (4)`,
`payload = signature(64) || recipientNodeId(16) = 80 bytes`. Canonical signed
preimage = `"GMP2-ACK"(8 ASCII) || msgId(16) || recipientNodeId(16) = 40 bytes`,
Ed25519 (RFC 8032, no prehash) — BouncyCastle on Android (`:core`), CryptoKit
`Curve25519.Signing` on iOS, byte-identical signatures.

### Cross-platform twins

| concern | Android | iOS |
|---|---|---|
| state machine | `mesh/delivery/DeliveryTracker.kt` | `GodstoneMesh/DeliveryTracker.swift` |
| ACK verify | `mesh/delivery/AckAuthenticator.kt` | `GodstoneMesh/AckAuthenticator.swift` |
| durable journal | `mesh/delivery/FileDeliveryJournal.kt` | `GodstoneMesh/FileDeliveryJournal.swift` |
| Ed25519 primitive | `core/crypto/Ed25519Keys.kt` (sign/verify) | CryptoKit (system) |

### Repo evidence (host-side, no device/radio)

`DeliveryTrackerTest` (Android, 12 tests) and `DeliveryTrackerTests` (iOS, 12
tests) drive the **real** tracker + `Ed25519AckAuthenticator` with a **real**
Ed25519 keypair and, for the reboot path, a **real on-disk**
`FileDeliveryJournal` reopened by a fresh tracker. They assert: the happy path
reaches `ACKNOWLEDGED` only with an authenticated ACK; an ACK that fails
authentication does not advance state; an ACK for the wrong message id is
rejected (replay X vs Y); a tampered signature is rejected; an ACK signed by the
wrong recipient is rejected; a non-ACK frame is rejected on type; the full
truth-table for `enqueue` / `markHandedToRelay` / `expire` / `cancel` with
idempotent terminal semantics; idempotent re-ack; and reboot recovery across a
fresh tracker over the same journal file. Android `:mesh` = 92; iOS `swift test`
= 94, `xcodebuild GodstoneMeshTests` (simulator) = 81.

### Still open (why this ADR is not closed)

On-device delivery is not proven (no captured radio, no real GATT round-trip,
no multi-recipient / retry / timeout behavior on hardware); the
`RecipientKeyResolver` in production must bind node id → public key via the
Noise_XX handshake / contact registry (tested here with an injected resolver);
and SOS-specific UI-phrase-vs-evidence rules are not yet wired. The radio/link
layer is disabled, so `ACKNOWLEDGED_BY_RECIPIENT` is reachable only in the
host-side state-machine tests.

### Amendment (T38): the one signed-SOS envelope

Before this amendment the isles signed distress **differently**: Android's
`Router.buildSos` emitted a structural frame whose 64-octet signature slot was
all zeros, and iOS `dispatchSos` signed an ad-hoc transcript of a different
shape. Two isles, two envelopes, no single word about what an authenticated
SOS *is*. This amendment fixes the canon; the runtime helpers
`wire/v2/SignedSosV1.{kt,swift}` (hand-written under the codegen exclusion,
following the `MessageId`/`SignedMessageV1` precedent) realise it on both
isles, composing the frozen authorities only -- `MessageId.derive`,
`IdentityBindingV1` (T13), the Ed25519 layer.

The canon, as recorded in `wire/wire_v2.yaml sos_requirements`:

```text
frame.payload    = ASCII("SOS1") || signature(64) || unsigned payload
unsigned payload = version(1)=0x01 || identityBinding(133)
                 || created_at(4, LE) || time_quality(1) || nonce(16)
                 || body_len(2, BE) || body (strict UTF-8, at most 400 octets)
msg_id           = BLAKE2s-128("GMP2-MSGID" || node || created_at LE || nonce
                               || UNSIGNED payload)      -- MessageId.derive,
                                 frozen formula, run over the UNSIGNED span
signature        = Ed25519(signing seed,
                           msg_id || ASCII("SOS1") || unsigned payload)
node             = BLAKE2s-128(embedded signing public key)  -- derived, never trusted
```

Five decisions, stated once:

1. **The structural fixtures stay structural.** The zero-signature golden SOS
   fixtures (§15) pass `SosFrameValidator` -- that is their purpose -- and are
   **refused by runtime authentication** under nine named reasons
   (`wrong_type, missing_required_flags, malformed, body_length,
   time_quality, unknown_time_pairing, message_id_mismatch,
   identity_binding, signature`). A structural codec test is not a
   signature-validity test, and no receiver may confuse the two.
2. **The authenticated key is not the verified person.** `verify` resolves the
   binding's embedded key and the node it hashes to; a caller may present a
   claimed identity (`expectedNodeId`) and the equation is checked against
   the *derivation*. Nothing on this path moves trust or approval state --
   that is the peer directory's separate layer (T26/T30 lineage).
3. **The relay decides first.** The router's epidemic verdict is computed and
   returned untouched; authentication rides beside it and only ever gates
   *indication promotion* to `SosObserver`. A refused frame still floods.
4. **Randomized signing is the platform, not a bug.** The host Ed25519 layer
   signs randomized (T83 finding), so cross-isle proof runs on **verification
   forms**: the pinned JVM-struck signatures of `crypto/sos_v1_vectors.json`
   must verify under the iOS verifier over the exact transcript, and fresh
   iOS authorship is asserted structurally plus by verifier acceptance --
   never byte-pinned. Because the msg_id hashes the binding that bears the
   seal, two hand-offs of one logical distress carry distinct msg_ids; the
   duplicate the seen cache speaks of is the retransmission of the **same
   envelope**, which is what idempotency is asserted across.
5. **Nil by default, loud at receivers.** `MeshNode.sosAuthority` and
   `sosObserver` are nil until the T54 lab composition root wires them; the
   legacy structural arm stays available and is refused by every conforming
   receiver. No composition outside ever presents an unauthenticated frame
   as an indication.

Evidence: both courts (`ReadinessT38Test.kt`, `ReadinessT38Tests.swift`)
read the **same** vector table at runtime -- one source of truth; eleven
witnesses per isle. The amendment moved no generated artefact: re-running
`wire/codegen.py` after it rewrites `WireV2.{kt,swift}` and the golden
vectors byte-identically (the generator reads the structural keys only; the
Hamming audit re-passes: minimum SOS distance 4), and the structural
zero-signature fixtures in `wire/golden_vectors.json` are untouched.
