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
preimage = `"GMP2-ACK"(7 ASCII) || msgId(16) || recipientNodeId(16) = 39 bytes`,
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
