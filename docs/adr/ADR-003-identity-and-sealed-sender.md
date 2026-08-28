# ADR-003 — Identity binding, TOFU, contacts, sealed sender

## 1. Status

**OPEN — PEER-IDENTITY ARCHITECTURE FROZEN, LOCAL IDENTITY AUTHORITY IMPLEMENTED, INTEGRATION / SEALED-SENDER / DEVICE EVIDENCE PENDING**

- **Phase C8.0 / C8.0.1 / C8.0.2 Architecture:** Accepted / Architecture Frozen (canonical Ed25519-rooted `IdentityBindingV1`, local generation authority, Noise XX payload placement, pre-HS3 initiator validation, dual-state pending rotation model, atomic trust transaction ownership in `PeerIdentityRepository`, pure `TrustPlan` engine, exact-candidate rotation approval, strict revocation semantics, physical store separation, and platform-precise coordinated panic-wipe integration).
- **Phase C8.1A / C8.1A.1 IdentityBinding Primitive:** Implemented & Frozen (canonical binary codec, 80-byte signature preimage, BLAKE2s-128 `node_id` derivation, pure `IdentityBindingValidator` with defensive copying, independent Python reference, and cross-platform locked KAT fixtures).
- **Phase C8.1B Local Identity Authority:** Implemented & Frozen (durable `LocalIdentityStateV1` authority, zero-parameter canonical local issuer, legacy migration, panic-wipe integration, platform CryptoKit/BouncyCastle signing, semantic and locked-KAT verification conformance to the canonical `IdentityBindingV1` contract, internal Keychain/SharedPreferences storage boundaries).
- **Phase C8.2A Pure Peer Trust Engine & Models:** Implemented & Frozen (pure deterministic `PeerTrustEngine`, 11-rule durable `PeerIdentityRecordValidator`, explicit persistence codes `TOFU_PINNED(1)`, `USER_VERIFIED(2)`, `REVOKED(3)`, effective state precedence, typed `PeerTrustRejectReason` / `TrustPlan` taxonomy, cross-platform decision matrix).
- **Phase C8.2B Durable Peer Trust Persistence:** Implemented & Frozen (physically separate durable `godstone_peer_identities.db` store, strict raw-row decoder D1-D5, serialized transactional `applyValidatedBinding`, read classification `PeerIdentityLookup`, and cross-connection concurrency evidence).
- **Phase C8.2C Peer Trust Lifecycle Authority:** Implemented & Frozen (exact-candidate rotation approval, durable revocation, guarded CAS transitions, trust preservation, and platform-precise coordinated panic-wipe peer-store integration repo-tested on Android and iOS).
- **Phase C8.3 Bound Recipient Key Resolver:** Implemented & Frozen (read-only durable peer-identity -> ACK signing-key authority, fail-closed matrix, stateless evaluation, no-mutation boundary, and full ACK authenticator integration on Android and iOS; runtime composition installation deferred to C8.4B).
- **Phase C8.4A Trusted Noise Handshake & READY Authority:** Implemented & Frozen (typed `HandshakeReadResult` inspection, iOS HS2/HS3 separation, `TrustedHandshakeController` with `IdentityBindingValidator`-gated trust, HS3-withheld on initiator trust failure/quarantine, READY-withheld on responder trust failure/quarantine, application seal/open gated on explicit READY state, and canonical 32/229/197 size assertions on both platforms).
- **Phase C8.4B Runtime Composition:** Implemented & Frozen (trusted controller-backed `SessionManager` installed, `BoundRecipientKeyResolver` installed in non-shipping mesh graph, runtime-aware wipe composition active, deterministic store closure before `eraseKeys`, startup pending-wipe barrier, old runtime permanently invalidated, LIGHT still Archive-only, BLE handshake record driver still open, link false).
- **Phase C8.4C Canonical BLE Record Layer:** Implemented & Frozen (canonical 8-byte record header, balanced-stride fragmentation, bounded 4-concurrent reassembly, duplicate suppression, sequence wrapping, fail-closed metadata/payload conflict rejection, encrypt-then-fragment semantic integrity, pure 32/229/197 handshake record composition tests, independent Python reference `wire/ble_record_reference.py`, locked golden vectors `wire/ble_record_vectors.json`, and structural control checker `ci/check_ble_record_controls.py` enforcing BR01–BR23).
- **Phase C8.4D1 Persistent Duplex BLE Link Substrate:**
  - **C8.4D1-A1 LinkInfo Role-Binding Amendment:** Implemented & Frozen (Connect-First / Elect-Before-Handshake, generated `LINK_INFO_UUID`, 13-byte `BleLinkInfoV1` canonical characteristic payload, provisional GATT connection state machine, simultaneous connect deterministic elimination proof, CBPeripheral/CBCentral identifier separation, and ADR-003 security binding).
  - **C8.4D1-R2.2 Substrate Implementation & Closure:** Implemented & Frozen (Authoritative state progression, precomputed snapshot provider, generation ownership tracking, peer publication gating on duplex readiness, and 100% negative mutation selftests).
- **Phase C8.4D2 Trusted Handshake Driver:** OPEN / NOT STARTED (trusted handshake state machine driving C8.4C records over C8.4D1 substrate).
- **Phase C8.4 Noise & Handshake Trust Gating:** OPEN (C8.4A/B/C/D subphases, full C8.4 parent integration open).
- **Sealed-Sender Authenticated Authorship:** OPEN (underlying L4 application envelope open).
- **Production `RecipientKeyResolver`:** UNRESOLVED in shipping path (Archive-only / Mesh absent); non-shipping mesh runtime resolver is bound and fail-closed by peer trust.
- **Link Layer:** Disabled (`LINK_LAYER_READY = false` / `linkLayerReady = false`).

> [!WARNING]
> During C8.4A the existing SessionManager is UNTRUSTED / NOT RUNTIME-AUTHORITATIVE for peer-trust READY. Its established() predicate reflects Noise cryptographic establishment only. It remains unreachable behind linkLayerReady=false / LINK_LAYER_READY=false. C8.4B must replace or refactor this authority before any link-layer enablement.

---

## 2. Problem Statement

GODSTONE nodes possess two distinct long-term cryptographic key pairs:
1. An **Ed25519** signing key pair used for message authorship, ACK signatures, and contact identification.
2. An **X25519** static Diffie-Hellman key pair used for the `Noise_XX_25519_ChaChaPoly_BLAKE2s` transport session.

In the baseline GMP/2.1 specification, node identity is defined as:
```text
node_id = BLAKE2s-128(identity_signing_public_key)  [over Ed25519]
```

However, the transport layer establishes encrypted sessions using the `Noise_XX` handshake, which cryptographically authenticates only the **X25519** static public key (`NoiseSession.remoteStaticKey`).

Without an explicit, authenticated binding between the Ed25519 signing key and the X25519 static DH key:
- A successfully completed Noise XX handshake proves possession of an X25519 private key, but proves **nothing** about the peer's claimed `node_id` or Ed25519 signing key.
- An active attacker can present their own X25519 key in Noise while claiming a victim's `node_id` / Ed25519 key, or replay unauthenticated routing hints.
- The Trust-On-First-Use (TOFU) model, out-of-band QR verification, key-change warnings, and the `RecipientKeyResolver` used for ACK verification cannot be grounded in cryptographic authority.

---

## 3. Decision

1. **Retain Ed25519 as the Canonical Identity Root:**
   ```text
   node_id = BLAKE2s-128(signing_public_key)
   ```
   We explicitly reject the earlier exploratory recommendation to invert the identity root to `H(X25519_static)`. The Ed25519 key remains the authoritative root of identity across all layers (wire, delivery, ACK, call signs, and QR verification).

2. **Close the Cryptographic Gap via Canonical Signed Binding:**
   We establish a canonical, self-signed identity certificate object—`IdentityBindingV1`—that cryptographically binds the node's X25519 static DH public key to its Ed25519 signing public key.

3. **Owned Local Binding Generation Authority:**
   Local bindings obtain their generation index exclusively from owned persistent state (`LocalIdentityBindingState`). Generation starts at 0, migrates legacy identities to 0 once, and strictly fails closed without wrapping at `UINT32_MAX`.

4. **Carry the Binding Exclusively Inside Encrypted Noise XX Payloads:**
   The binding is exchanged within the encrypted handshake payloads of `Noise_XX` (HS2 and HS3). It is never sent in plaintext BLE records and introduces zero additional round trips.

5. **Initiator Pre-HS3 Validation Contract:**
   The initiator validates the responder's `IdentityBindingV1` and evaluates trust policy **before** emitting HS3. An invalid or quarantined responder never receives the initiator's identity binding.

6. **Atomic Trust Evaluation & Repository Transaction Ownership:**
   `PeerTrustEngine` is a pure function that emits a `TrustPlan`. `PeerIdentityRepository` executes evaluation and mutation inside a single atomic write transaction (`BEGIN IMMEDIATE`), guaranteeing serialized consistency under concurrent sessions.

7. **Exact-Candidate Rotation Approval & Revocation Contracts:**
   Rotation approval requires exact compare-and-swap matching against the candidate reviewed by the user, leaving provenance unchanged. Revocation atomically clears pending candidates and permanently revokes identity authority.

8. **Physical Store Separation & Platform-Precise Panic Wipe:**
   `PeerIdentityStore` is logically and physically separated from the frozen C7 message store, and is integrated into the coordinated, resumable ADR-004 panic-wipe coordinator.

---

## 4. `IdentityBindingV1` Canonical Encoding

### 4.1 Structure and Field Layout

`IdentityBindingV1` is a fixed-size, 133-byte binary structure:

| Offset | Size | Field Name | Type / Encoding | Description |
|---|---|---|---|---|
| `0` | `1` | `version` | `uint8` (`0x01`) | Identity binding structure version |
| `1` | `4` | `generation` | `uint32_be` | Monotonic key rotation generation index |
| `5` | `32` | `signing_public_key` | `bytes[32]` | Authoritative Ed25519 signing public key |
| `37` | `32` | `static_dh_public_key` | `bytes[32]` | X25519 static DH public key bound to this identity |
| `69` | `64` | `signature` | `bytes[64]` | Ed25519 signature over the canonical preimage |

**Total Serialized Payload:** Exactly **133 bytes**.

### 4.2 Deterministic `node_id` Derivation
To eliminate redundant, attacker-controlled representations, `node_id` is **NOT** included in the serialized binding. The receiving peer deterministically derives:
```text
node_id = BLAKE2s-128(signing_public_key)
```

### 4.3 Signature Domain and Preimage
The signature is generated by the peer's Ed25519 private key over an 80-byte canonical preimage:

```text
Preimage = ASCII("GMP2-IDBIND")
           || version[1]
           || generation_be[4]
           || signing_public_key[32]
           || static_dh_public_key[32]
```

- **Domain Tag:** `ASCII("GMP2-IDBIND")` (11 bytes: `0x47, 0x4D, 0x50, 0x32, 0x2D, 0x49, 0x44, 0x42, 0x49, 0x4E, 0x44`)
- **Total Preimage Length:** `11 + 1 + 4 + 32 + 32 = 80 bytes`.
- **Signature Algorithm:** Standard Ed25519 (RFC 8032 / PureEd25519).

---

## 5. Local Binding Generation Authority & Lifecycle

### 5.1 Local Identity State
The local node manages its own identity and binding issuance via:

```text
LocalIdentityBindingState:
    signingKeyPair:      Ed25519KeyPair
    staticDhKeyPair:     X25519KeyPair
    bindingGeneration:   uint32
```

- **Issuance Invariant:** Local `IdentityBindingV1` construction MUST obtain `generation` from this owned local state. Production binding generation must NOT accept an arbitrary caller-supplied generation parameter.
- **Fresh Identity:** A freshly created local identity initializes `bindingGeneration = 0`.
- **Panic Wipe Regeneration:** An identity regenerated following a panic wipe initializes `bindingGeneration = 0`.

### 5.2 Legacy Identity Migration Rule
Existing GODSTONE identities created prior to Phase C8 possess valid Ed25519 and X25519 key pairs but lack persistent generation metadata.
- **Canonical Migration:** The migration path initializes `bindingGeneration = 0` exactly once.
- **Post-Migration Integrity:** After initial migration, any missing local generation metadata is treated as identity-state corruption and fails closed.

### 5.3 Rotation Scope & Wrap Prevention
- **C8.1 Scope:** C8.1 implements local generation ownership, generation-0 local issuance, and remote validation/trust policy. Dedicated local static-key rotation UI commands remain for a future phase.
- **No-Wrap Invariant:** The generation counter MUST NEVER wrap. If `bindingGeneration == UINT32_MAX`, any future rotation attempt fails closed. An overflow from `UINT32_MAX -> 0` is strictly forbidden.

---

## 6. Noise XX Placement & Handshake Sequencing

The binding is transmitted inside the standard encrypted handshake payload slots of `Noise_XX_25519_ChaChaPoly_BLAKE2s`:

```text
HS1 (initiator -> responder):
    -> e
    payload: EMPTY (0 bytes)
    Message Size: 32 bytes

HS2 (responder -> initiator):
    <- e, ee, s, es
    payload: Encrypted responder IdentityBindingV1 (133 bytes)
    Message Size: 32 (e) + 48 (encrypted static) + 149 (encrypted binding) = 229 bytes

HS3 (initiator -> responder):
    -> s, se
    payload: Encrypted initiator IdentityBindingV1 (133 bytes)
    Message Size: 48 (encrypted static) + 149 (encrypted binding) = 197 bytes
```

### 6.1 Initiator Handshake Sequencing Invariant
The initiator MUST execute the following sequence:
1. Send HS1 (32 bytes).
2. Receive and Noise-decrypt HS2 (229 bytes).
3. Extract responder's decrypted `IdentityBindingV1` and authenticated `remoteStaticKey`.
4. Perform pure cryptographic validation (Steps 1–10).
5. Apply trust policy via `PeerIdentityRepository.applyValidatedBinding(...)`.
6. **IF AND ONLY IF** the decision is `Accepted` or `FirstSeenPinned`:
   - Construct local `IdentityBindingV1`.
   - Encrypt and transmit HS3 (197 bytes).
   - Advance to `NOISE_ESTABLISHED` $\to$ `READY`.
7. **OTHERWISE (Rejected or KeyChangedQuarantined):**
   - **DO NOT SEND HS3.**
   - Abort handshake or record quarantine, and disconnect.

*Rationale:* An invalid or quarantined responder must never be given the initiator's Ed25519 identity binding.

### 6.2 Responder Handshake Sequencing
1. Receive HS1 (32 bytes).
2. Transmit HS2 containing encrypted responder `IdentityBindingV1` (229 bytes).
3. Receive and Noise-decrypt HS3 (197 bytes).
4. Perform pure cryptographic validation and apply trust policy via `PeerIdentityRepository.applyValidatedBinding(...)`.
5. If accepted, advance to `NOISE_ESTABLISHED` $\to$ `READY`. If rejected/quarantined, disconnect.

*Note:* The responder necessarily reveals its encrypted HS2 binding before knowing the initiator's identity; this is standard and accepted Noise XX responder behavior.

---

## 7. Required Validation Pipeline

Validation is strictly divided into two phases: **Pure Cryptographic Validation** (Steps 1–10) and **Atomic Trust Evaluation & Repository Mutation** (Steps 11–13).

### 7.1 Pure Cryptographic Validation (Steps 1–10)
Steps 1 through 10 MUST be pure functions with respect to `PeerIdentityStore`. Failure at any of these steps results in immediate `SECURITY_REJECT`, produces no store mutations, and aborts the connection:

1. **Length Check:** Require decrypted payload length is exactly 133 bytes.
2. **Version Check:** Require `version == 0x01`.
3. **Generation Parse:** Read `generation` as big-endian `uint32`.
4. **Signing Key Parse:** Extract `signing_public_key` (32 bytes).
5. **Static DH Key Parse:** Extract `static_dh_public_key` (32 bytes).
6. **Signature Parse:** Extract `signature` (64 bytes).
7. **Cryptographic Signature Verification:** Verify `signature` under `signing_public_key` over the 80-byte `GMP2-IDBIND` preimage.
8. **Node ID Derivation:** Compute `derived_node_id = BLAKE2s-128(signing_public_key)`.
9. **Noise Static Match:** Require `binding.static_dh_public_key == NoiseSession.remoteStaticKey`.
10. **Advertisement Consistency Check:** Require `advertised_node_hint == first4(derived_node_id)`.

Upon success of Steps 1–10, the intermediate object `ValidatedPeerBinding` is produced:
```text
ValidatedPeerBinding:
    nodeId:            bytes[16]
    signingPublicKey:  bytes[32]
    staticDhPublicKey: bytes[32]
    generation:        uint32
```

### 7.2 Advertised Hint Security Statement
The 4-byte discovery hint (`node_hint`) is **NOT** an authenticated identity:
- The hint is truncated (4 bytes / 32 bits), non-unique, and subject to accidental or malicious collision.
- It cannot serve as a durable database key or as a `RecipientKeyResolver` lookup key.

**Formal Security Claim:**
After successful validation through Step 10:
1. The authenticated Noise static DH key is cryptographically bound to the Ed25519 signing public key.
2. The Ed25519 signing public key deterministically derives the full 16-byte `node_id`.
3. The observed 4-byte `advertised_node_hint` is proven **CONSISTENT WITH** `first4(node_id)`.

The full 16-byte `node_id` MUST be used everywhere across the system following identity validation.

### 7.3 Runtime Authority and Trusted SessionManager Composition (Phase C8.4B)
> [!NOTE]
> In Phase C8.4B, the runtime SessionManager has been fully replaced/refactored on both Android and iOS to own `TrustedHandshakeController` instances rather than raw Noise establishment. Application sealing and opening are gated strictly on `HandshakeTrustState.READY`.
> The runtime composition graph (`BoundRecipientKeyResolver`, `PeerIdentityRepository`, `SessionManager`, `DefaultRuntimeLifecycleGate`) is installed in the non-shipping mesh runtime while shipping iOS `AppContainer` and Android Light roots remain strictly Archive-only with `linkLayerReady = false` / `LINK_LAYER_READY = false`.

---

## 8. Atomic Trust Evaluation & Repository Transaction Ownership

Evaluating trust and mutating durable state based on an uncoordinated read outside a transaction is fundamentally unsafe under concurrent connection attempts.

### 8.1 Pure Decision Function vs. Transaction Owner
- **`PeerTrustEngine`:** A pure decision engine with no I/O. Given a `ValidatedPeerBinding` and a snapshot `PeerIdentityRecord?`, it deterministically computes a `TrustPlan`.
- **`PeerIdentityRepository`:** Owns the database connection, owns the serialized transaction boundary (`BEGIN IMMEDIATE`), reads current authority, executes the `TrustPlan`, verifies row cardinality, and returns a `PeerTrustApplyResult`.

### 8.2 Canonical Public Repository API
```text
PeerIdentityRepository.applyValidatedBinding(
    binding: ValidatedPeerBinding
) -> PeerTrustApplyResult
```

### 8.3 Transaction Execution Flow
`applyValidatedBinding` MUST execute inside a single serialized write transaction:

```text
BEGIN IMMEDIATE;

1. Read current PeerIdentityRecord by full 16-byte nodeId.
2. Validate durable row invariants (Section 10.3). If invalid -> ROLLBACK, return Corrupt.
3. Call pure PeerTrustEngine.evaluate(binding, currentRow) -> TrustPlan.
4. Execute SQL corresponding to the TrustPlan:
   - AcceptExisting:             Update last_authenticated_timestamp (informational).
   - InsertFirstSeen:            INSERT row with acceptedGeneration=binding.gen, acceptedStatic=binding.static, trustLevel=TOFU_PINNED.
   - SetInitialPendingCandidate: UPDATE row SET pendingGeneration=binding.gen, pendingStaticDhPublicKey=binding.static WHERE acceptedGeneration=A AND pendingGeneration IS NULL.
   - AdvancePendingCandidate:    UPDATE row SET pendingGeneration=binding.gen, pendingStaticDhPublicKey=binding.static WHERE acceptedGeneration=A AND pendingGeneration=P.
   - KeepQuarantined:            No SQL mutation (or update informational metadata).
   - Reject(reason):             No SQL mutation.
5. Verify exact affected-row cardinality (e.g. CAS update affected exactly 1 row).
6. Derive PeerTrustApplyResult from committed state.

COMMIT;
```

- Any SQL failure or concurrency conflict triggers `ROLLBACK` and returns `StorageFailure`.
- A corrupt persisted row triggers `ROLLBACK` and returns `Corrupt`.
- A mutating `TrustPlan` is NEVER computed from an uncoordinated row read outside the write transaction.

### 8.4 Pure `TrustPlan` Model
```text
TrustPlan:
    AcceptExisting
    InsertFirstSeen
    SetInitialPendingCandidate
    AdvancePendingCandidate
    KeepQuarantined
    Reject(reason: PeerTrustRejectReason)
```

### 8.5 Public `PeerTrustApplyResult`
```text
PeerTrustApplyResult:
    Accepted(VerifiedPeerIdentity)
    FirstSeenPinned(VerifiedPeerIdentity)
    KeyChangedQuarantined(PendingPeerIdentity)
    Rejected(reason: PeerTrustRejectReason)
    StorageFailure
    Corrupt
```

**Reject Reasons:**
- `Rollback`
- `SameGenerationConflict`
- `PendingGenerationConflict`
- `StaleRelativeToPending`
- `NoncanonicalGenerationAdvance`
- `NodeIdSigningKeyCollision`
- `Revoked`

---

## 9. Concurrency & Race Invariants

The repository transaction guarantees the following properties under concurrent multi-connection races:

1. **Concurrent First-Seen Sessions:** Two simultaneous incoming connections from the same unseen peer race to insert. Exactly one transaction commits `InsertFirstSeen` (returning `FirstSeenPinned`); the second transaction observes the committed row and executes `AcceptExisting` (returning `Accepted`). Final durable state has exactly one canonical accepted binding.
2. **Concurrent Node-ID Collision:** Two different signing keys with colliding `node_id` race. Exactly one key becomes the stored authority; the competing key fails signing key equality check in the serialized transaction and receives `NodeIdSigningKeyCollision`. Never last-writer-wins.
3. **Concurrent Pending Candidates (gen 5 vs gen 6):** Regardless of scheduling order, the higher valid generation (`gen = 6`) becomes the durable pending candidate. A `gen = 5` candidate arriving after `gen = 6` commits is rejected as `StaleRelativeToPending`. Pending generation never regresses.
4. **Concurrent Identical Pending Candidate:** Idempotently returns `KeyChangedQuarantined` without row churn or state corruption.
5. **Monotonicity Invariant:** No transaction may ever regress `acceptedGeneration` or `pendingGeneration`.

---

## 10. Durable Peer Identity Model & Physical Store Separation

### 10.1 Physical Store Separation
To preserve the frozen C7 durable message store contract:
- `PeerIdentityStore` is a **SEPARATE logical and physical database** from the C7 held-frame and delivery store (`StoreSchema`).
- **No Cross-Store Schema Coupling:** No columns or tables are added to the C7 message store.
- **Independent Lifecycles:** Peer trust and message routing operate with isolated migrations and schemas.

### 10.2 Platform Protected Storage

#### iOS Data Protection Contract (Frozen in C8.2A for C8.2B Implementation)
- **Dedicated Database:** Dedicated SQLite database (`godstone_peer_identities.sqlite3`).
- **Protection Class:** `FileProtectionType.complete` at rest, matching `SqliteMessageStore`.
- **Locked-Device Operational Boundaries:**
  - C8 does NOT currently promise locked-device relay or `READY` mesh operation.
  - `MeshIdentity`'s Keychain use of `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` does NOT by itself establish a locked-device mesh guarantee.
  - `PeerIdentityStore` and `SqliteMessageStore` remain completely unavailable under `FileProtectionType.complete` while the device is locked.
  - Any future decision to support locked-device relay must change BOTH message and peer-store availability as a separate, threat-reviewed phase backed by device evidence.
  - `C8.2B` must NOT silently choose `.completeUntilFirstUserAuthentication`.

#### Android Storage Contract (Predeclared in C8.2A for C8.2B Implementation)
- **Dedicated Database:** Dedicated SQLCipher database (`godstone_peer_identities.db`).
- **Passphrase Authority:** Dedicated 32 random bytes passphrase stored in a separate `EncryptedSharedPreferences` namespace protected by Android Keystore.
- **Physical Separation:** Do NOT reuse `godstone_messages.db` and do NOT add peer tables to `StoreSchema`.

### 10.3 Logical Schema & Durable Invariants (`PeerIdentityRecord`)
```text
PeerIdentityRecord:
    nodeId:                      bytes[16]  (Primary Key)
    signingPublicKey:            bytes[32]  (NOT NULL)
    acceptedStaticDhPublicKey:   bytes[32]  (NOT NULL)
    acceptedGeneration:          uint32     (NOT NULL, 0..UINT32_MAX)
    trustLevel:                  TrustLevel (NOT NULL: TOFU_PINNED | USER_VERIFIED | REVOKED)
    pendingStaticDhPublicKey:    bytes[32]? (NULLABLE)
    pendingGeneration:           uint32?    (NULLABLE)
```

**Durable Invariants (Enforced by Schema & Repository):**
- `nodeId` is exactly 16 bytes.
- `signingPublicKey` and `acceptedStaticDhPublicKey` are exactly 32 bytes.
- **Pending Coupling:** `pendingStaticDhPublicKey` and `pendingGeneration` MUST be both `NULL` or both non-`NULL`.
- **Pending Key Divergence:** When present, `pendingStaticDhPublicKey != acceptedStaticDhPublicKey`.
- **Pending Monotonic Advance:** When present, `pendingGeneration > acceptedGeneration` and `pendingGeneration <= UINT32_MAX`.
- **Revocation Coupling:** When `trustLevel == REVOKED`, pending fields MUST be `NULL`.
- **Informational Metadata:** Timestamps (`first_seen_timestamp`, `last_authenticated_timestamp`) are purely informational. They are NOT signature inputs, NOT generation authorities, NOT rollback authorities, and NEVER influence cryptographic trust.

---

## 11. Effective State Precedence

To eliminate overlapping or ambiguous states, the canonical effective state is strictly evaluated in precedence order:

```text
if trustLevel == REVOKED:
    effectiveState = REVOKED
else if pendingGeneration != null:
    effectiveState = KEY_CHANGED_QUARANTINED
else if trustLevel == USER_VERIFIED:
    effectiveState = ACTIVE_USER_VERIFIED
else:
    effectiveState = ACTIVE_TOFU
```

- A persisted record containing `trustLevel == REVOKED` and non-null pending fields is considered `Corrupt`.
- An active identity is NEVER simultaneously `REVOKED` and quarantined.

---

## 12. Trust Decision Matrices

### 12.1 TOFU Terminology & First-Seen Generation Rule
- **`TOFU_PINNED` Definition:** Established from the first cryptographically valid, Noise-bound `IdentityBindingV1` for this `node_id`, but not independently user/OOB verified.
- **First-Seen Generation Rule:** An unseen `node_id` presenting a valid `IdentityBindingV1` with **ANY** `uint32` generation becomes the initial TOFU baseline (e.g. first encounter at `generation = 7` with static $K_7 \implies$ store `acceptedGeneration = 7`, `acceptedStatic = K_7`, `trustLevel = TOFU_PINNED`).

### 12.2 Known-Peer Evaluation Matrix (No Pending Rotation)
Let $A = \text{acceptedGeneration}$ and $K_A = \text{acceptedStaticDhPublicKey}$:

| Incoming `generation` | Incoming `static_dh_public_key` | Signing Key Check | Decision / Action |
|---|---|---|---|
| `gen == A` | `static == KA` | `signing == stored` | **Accepted:** Ordinary reconnect $\to$ `VerifiedPeerIdentity` created $\to$ `READY`. |
| `gen < A` | Any | `signing == stored` | **SECURITY_REJECT (Rollback):** Disconnect. |
| `gen == A` | `static != KA` | `signing == stored` | **SECURITY_REJECT (SameGenerationConflict):** Disconnect. |
| `gen > A` | `static == KA` | `signing == stored` | **SECURITY_REJECT (NoncanonicalGenerationAdvance):** Disconnect. |
| `gen > A` | `static != KA` | `signing == stored` | **KeyChangedQuarantined:** Set initial pending candidate (`pendingGeneration = gen`, `pendingStatic = static`) $\to$ Disconnect / No `READY`. Accepted fields unchanged. |
| Any | Any | `signing != stored` | **SECURITY_REJECT (NodeIdSigningKeyCollision):** Disconnect $\to$ No store mutation. |

### 12.3 Known-Peer Evaluation Matrix (Pending Rotation Exists)
Let $A = \text{acceptedGeneration}$, $K_A = \text{acceptedStaticDhPublicKey}$, $P = \text{pendingGeneration}$, $K_P = \text{pendingStaticDhPublicKey}$ ($P > A, K_P \neq K_A$):

| Incoming `generation` | Incoming `static_dh_public_key` | Decision / Action |
|---|---|---|
| `gen == P` | `static == KP` | **KeyChangedQuarantined (KeepQuarantined):** Idempotent re-encounter $\to$ Remain quarantined $\to$ No `READY`. |
| `gen == A` | `static == KA` | **KeyChangedQuarantined (KeepQuarantined):** Reconnect of old accepted binding while pending rotation unresolved $\to$ Remain quarantined $\to$ No `READY`. |
| `gen < A` | Any | **SECURITY_REJECT (Rollback):** Disconnect. |
| `gen == A` | `static != KA` | **SECURITY_REJECT (SameGenerationConflict):** Disconnect. |
| `A < gen < P` | Any | **SECURITY_REJECT (StaleRelativeToPending):** Disconnect. |
| `gen == P` | `static != KP` | **SECURITY_REJECT (PendingGenerationConflict):** Disconnect. |
| `gen > P` | `static != KP` and `static != KA` | **KeyChangedQuarantined (AdvancePendingCandidate):** Update pending candidate (`pendingGeneration = gen`, `pendingStatic = static`) $\to$ Remain quarantined $\to$ No `READY`. |
| `gen > A` | `static == KA` | **SECURITY_REJECT (NoncanonicalGenerationAdvance):** Disconnect. |
| `gen > P` | `static == KP` | **SECURITY_REJECT (NoncanonicalGenerationAdvance):** Disconnect. |

**Strict Rule:** No incoming packet, timeout, or reboot can clear quarantine. Quarantine resolution requires explicit local user action.

---

## 13. Exact-Candidate Rotation Approval Semantics

Promoting a pending key change requires an explicit local user action targeting the **exact candidate** presented in the UI:

### 13.1 Public Approval API
```text
PeerIdentityRepository.approvePendingRotation(
    nodeId:                           bytes[16],
    expectedPendingGeneration:        uint32,
    expectedPendingStaticDhPublicKey: bytes[32]
) -> RotationApprovalResult
```

### 13.2 Atomic CAS Execution Flow
```text
BEGIN IMMEDIATE;

1. Read current PeerIdentityRecord by full nodeId.
2. If row not found -> ROLLBACK, return PeerNotFound.
3. If trustLevel == REVOKED -> ROLLBACK, return RejectedRevoked.
4. If pendingGeneration == null -> ROLLBACK, return NoPendingCandidate.
5. If pendingGeneration != expectedPendingGeneration
   OR pendingStaticDhPublicKey != expectedPendingStaticDhPublicKey:
   -> ROLLBACK, return StaleCandidate.
6. Atomically update row:
   UPDATE peer_identities SET
       acceptedGeneration        = pendingGeneration,
       acceptedStaticDhPublicKey = pendingStaticDhPublicKey,
       pendingGeneration         = NULL,
       pendingStaticDhPublicKey  = NULL
   WHERE nodeId = :nodeId
     AND pendingGeneration = :expectedPendingGeneration
     AND pendingStaticDhPublicKey = :expectedPendingStaticDhPublicKey;
7. Verify exactly 1 row updated.
8. Preserve existing trustLevel (TOFU_PINNED remains TOFU_PINNED, USER_VERIFIED remains USER_VERIFIED).

COMMIT;
```

- **Stale Candidate Protection:** If a newer candidate (`gen = 6`) arrived while the user was reviewing `gen = 5`, approving `gen = 5` returns `StaleCandidate` and promotes nothing. The user must review `gen = 6`.
- **Provenance Preservation:** Approving a key rotation MUST NOT elevate `TOFU_PINNED` to `USER_VERIFIED`. Out-of-band verification (e.g. QR scan) remains a separate, explicit user action.
- **No Unsafe Discard:** We explicitly reject defining an operation that discards a pending candidate and resumes the old static key. Because higher-generation certificates are signed by the Ed25519 root, silently returning to an older key destroys rollback protection.

---

## 14. Revocation Contract

Revocation permanently strips an identity of communication authority:

### 14.1 Public Revocation API
```text
PeerIdentityRepository.revokePeer(nodeId: bytes[16]) -> RevokeResult
```

### 14.2 Atomic Revocation Execution Flow
```text
BEGIN IMMEDIATE;

UPDATE peer_identities SET
    trustLevel                = 'REVOKED',
    pendingGeneration         = NULL,
    pendingStaticDhPublicKey  = NULL
WHERE nodeId = :nodeId;

COMMIT;
```

- **Zero Authority:** Accepted fields may remain stored for forensic/audit history, but have ZERO authority.
- **Resolver & Link Status:** `RecipientKeyResolver` returns `null`. Link layer never reaches `READY`.
- **Inbound Packets:** Inbound bindings for a revoked identity return `Rejected(Revoked)`.
- **No Automatic Un-Revoke:** No incoming packet, generation advance, or timeout can un-revoke an identity.

---

## 15. Recipient Key Resolution Contract

The production placeholder:
```kotlin
UnresolvedRecipientKeyResolver  // Fail-closed
```
### 15.1 Production Resolver Contract (`BoundRecipientKeyResolver`)
In Phase C8.3, `BoundRecipientKeyResolver` resolves `node_id -> Ed25519 signing public key` under strict conditions:
- **Authorized Returns:** Returns `signingPublicKey` **ONLY** when:
  1. `PeerIdentityLookup.Verified` is returned (no pending rotation candidate exists, not revoked), and
  2. `trustLevel` is `TOFU_PINNED` or `USER_VERIFIED`.
- **Null Returns:** MUST return `null` (causing ACK verification to fail closed) for:
  - Unseen `node_id` (`NotFound`),
  - Quarantined peers (`Quarantined` / `pendingStaticDhPublicKey != null`),
  - Revoked peers (`Revoked` / `trustLevel == REVOKED`),
  - Corrupt storage records (`Corrupt`),
  - Storage I/O errors (`StorageFailure`),
  - Invalid arguments (`InvalidArgument`, `nodeId` length != 16).
- **Read-Only Authority:** `BoundRecipientKeyResolver` consumes a read-only `PeerIdentityLookupSource` / `PeerIdentityRepository.lookup` and performs NO store mutations, approvals, revocations, or key creations.
- **Stateless:** Never caches or memoizes keys; all invocations re-query durable authority.
- **Composition Boundary:** `BoundRecipientKeyResolver` is implemented and verified in GodstoneMesh tests, but runtime installation in `MeshModule` / `AppContainer` is intentionally deferred to Phase C8.4 where live peer store lifecycle, Noise handshake ingestion, and panic-wipe coordination are integrated together.
- *Authority Boundaries:* ACK frames, expected recipient delivery rows, and discovery advertisements NEVER create or mutate resolver mappings.

---

## 16. Role-Specific Link State Progression

```text
INITIATOR:
DISCONNECTED
    |
    v (Send HS1)
HS1_SENT
    |
    v (Receive & decrypt HS2)
HS2_DECRYPTED
    |
    v (Validate Steps 1-10 & apply trust transaction)
REMOTE_STATIC_AUTHENTICATED & BINDING_VALIDATED
    |
    +---> [If Rejected or Quarantined] ---> SECURITY_REJECT / QUARANTINE (NO HS3 SENT, Disconnect)
    |
    v [If Accepted or FirstSeenPinned]
HS3_SENT
    |
    v (Noise session established)
NOISE_ESTABLISHED
    |
    v
READY (FrameV2 application traffic enabled)


RESPONDER:
DISCONNECTED
    |
    v (Receive HS1, send HS2 with responder binding)
HS2_SENT
    |
    v (Receive & decrypt HS3)
HS3_DECRYPTED
    |
    v (Validate Steps 1-10 & apply trust transaction)
REMOTE_STATIC_AUTHENTICATED & BINDING_VALIDATED
    |
    +---> [If Rejected or Quarantined] ---> SECURITY_REJECT / QUARANTINE (Disconnect)
    |
    v [If Accepted or FirstSeenPinned]
NOISE_ESTABLISHED
    |
    v
READY (FrameV2 application traffic enabled)
```

**Strict Invariant:** Zero `FrameV2` application frames may be dispatched before reaching `READY`.

---

## 17. Future Noise API Requirements (Phase C8.1 Target)

To support pre-HS3 initiator validation and clean layering, Phase C8.1 requires platform Noise drivers to expose a typed handshake read result:

```text
HandshakeReadResult:
    payload:                      bytes
    authenticatedRemoteStaticKey: bytes[32]?
```

### 17.1 Platform Gaps to Resolve in C8.1
- **Android Gap:** `NoiseSession.remoteStaticKey` is currently populated only in `maybeSplit()`. C8.1 must expose `handshake.remotePublicKey` immediately upon successfully processing a handshake message containing `s` (i.e. after HS2 read on initiator, after HS3 read on responder) without requiring session splitting.
- **iOS Gap:** The existing `readMessage2AndWrite3(...)` driver combines reading HS2 and writing HS3 in a single uninspected call. C8.1 must split this into `readMessage2(...) -> HandshakeReadResult`, perform validation, and only then invoke `writeMessage3(localBindingPayload)`.

`NoiseSession` remains a purely cryptographic mechanism and contains no database or trust policy logic.

---

## 18. Platform-Precise Panic Wipe Contract (ADR-004 Integration)

We integrate `PeerIdentityStore` into the existing **coordinated, resumable, crypto-erasure-first** `PanicWipe` architecture defined in ADR-004:

### 18.1 Android Wipe Sequence
1. `eraseKeys()`: Destroys Android Keystore master key / KEK material (crypto-erasure of encrypted store keys).
2. `deleteArtifacts()`: Idempotently deletes durable message database (`SqliteMessageStore`), peer identity database (`PeerIdentityStore`), contact/verification state, and resolver backing files.
3. Regenerate fresh local identity (`generation = 0`).
4. Clear wipe journal.

### 18.2 iOS Wipe Sequence
1. `eraseKeys()`: Deletes local Ed25519 and X25519 Keychain identity secrets.
2. `deleteArtifacts()`: **Explicitly deletes** the SQLite message database, the SQLite peer identity database, contact/verification metadata, and resolver backing files.
   *(Critical Note: Deleting local iOS identity keys does NOT cryptographically erase SQLite stores protected under `FileProtectionType.complete`; `deleteArtifacts` must explicitly remove both database files).*
3. Regenerate fresh local identity (`generation = 0`).
4. Clear wipe journal.

- Cross-system "atomic" wipe claims across Keychain, SQLite, and memory are rejected.
- Crash before deletion $\implies$ Resumed wipe completes deletion.
- Crash after deletion $\implies$ Resumed wipe remains idempotent.
- **ADR-004 remains OPEN.**

---

## 19. Sealed Sender Dependency

Phase C8.0 / C8.0.1 / C8.0.2 resolves **transport peer identity binding** (L2 session authentication).

It does **NOT** resolve or close:
- **L4 Sealed Sender Authorship:** End-to-end sender authentication inside encrypted application envelopes without leaking sender identity to intermediate relays.
- **Relay Abuse Resistance:** Priority validation and PoW verification on sealed payloads.

Because sealed-sender authenticated authorship remains an open protocol design area, **ADR-003 remains OPEN**.

---

## 20. ACK Authentication Contract

Delivery ACK wire format and cryptographic signatures remain strictly preserved from Phase C7.4 / C7.5:
```text
ACK Preimage = ASCII("GMP2-ACK") || msg_id[16] || recipient_node_id[16]
Signature    = Ed25519Sign(recipient_signing_private_key, ACK Preimage)
```

The C8 architecture defines how `RecipientKeyResolver` supplies the verified `recipient_signing_public_key` to `AckAuthenticator`. C7.4 and C7.5 contracts remain frozen and unmodified.

---

## 21. Rejected Alternative: Inverting the Identity Root to `H(X25519)`

The earlier exploratory recommendation proposed setting `node_id = BLAKE2s-128(X25519_static_public_key)`.

### 21.1 Why This Alternative Was Rejected
1. **Explicit Signed Binding Closes the Gap:** A signed `IdentityBindingV1` provides complete bidirectional cryptographic proof without requiring a root change.
2. **Ed25519 Is Already Authoritative:** Application authorship, ACK signatures, and out-of-band contact verification are naturally signing operations. Rooting identity in Ed25519 keeps signing authority primary.
3. **Enables DH Rotation:** With an Ed25519 root, X25519 static DH keys can rotate (via `generation`) without breaking the peer's permanent `node_id`, call sign, or contact identity.
4. **Avoids Massive Blast Radius:** Inverting the root would invalidate all frozen GMP/2.1 wire vectors, golden fixtures, delivery stores, message IDs, and C6/C7 verification contracts.

---

## 22. Threat Analysis

| Threat Scenario | Attack Vector | Mitigation / System Response |
|---|---|---|
| **A. Spoofed Discovery Hint** | Attacker advertises a victim's `node_hint` to manipulate role election or routing. | Step 10 requires `advertised_node_hint == first4(derived_node_id)`. Mismatch causes immediate connection abort. |
| **B. Mismatched Keys** | Attacker presents own X25519 static key in Noise, but claims victim's Ed25519 signing public key. | Step 7 verifies signature over `IDBIND` preimage. Attacker cannot sign X25519 key without victim's Ed25519 private key $\to$ `SECURITY_REJECT`. |
| **C. Replayed Binding** | Attacker captures a valid victim `IdentityBindingV1` and replays it in their own Noise handshake. | Step 9 checks `binding.static_dh_public_key == NoiseSession.remoteStaticKey`. The victim's static key does not match attacker's ephemeral/static Noise session $\to$ `SECURITY_REJECT`. |
| **D. Rollback Attack** | Attacker replays an older, valid lower-generation binding for a victim whose key has rotated. | Section 12.2/12.3 checks `generation < acceptedGeneration` (or `< pendingGeneration`) $\to$ `SECURITY_REJECT (Rollback)` $\to$ Disconnect. |
| **E. Forked / Conflicting Binding** | Attacker presents a binding with same `generation` but different X25519 static key. | Section 12.2/12.3 checks `generation == stored_generation` with mismatched key $\to$ `SECURITY_REJECT (SameGenerationConflict)` $\to$ Disconnect. |
| **F. Legitimate Key Rotation** | Legitimate peer rotates X25519 key with `generation > acceptedGeneration` and valid signature. | Peer receives valid candidate. **Initiator observing quarantined responder in HS2:** DOES NOT send HS3; handshake aborts; no READY. **Responder observing quarantined initiator in HS3:** Receives HS3, but trust policy blocks READY and link is torn down/quarantined. |
| **G. First-Seen Attacker Identity** | Attacker creates a fresh, valid self-signed identity and connects. | Accepted as a new `TOFU_PINNED` peer, but possesses zero privileges, no existing contact trust, and cannot resolve as any existing contact. |
| **H. Ed25519 Root Compromise** | Attacker steals victim's Ed25519 private key. | Identity is fully compromised. Attacker can issue valid bindings. Cryptographic recovery is impossible; requires out-of-band revocation and key regeneration. |
| **I. X25519 Static Compromise Only** | Attacker steals victim's X25519 private key, but NOT Ed25519 signing key. | Attacker can impersonate only the compromised static session for that generation. Attacker cannot advance `generation` or bind a new DH key without the Ed25519 key. |
| **J. Panic Wipe** | Device owner triggers emergency local data wipe. | Both private keys, all session state, and peer stores are destroyed. Device regenerates a new identity with a fresh `node_id` (`generation = 0`). |

---

## 23. Adversarial Architecture Q&A

1. **Can two concurrent trust evaluations regress pending gen6 to gen5?**
   **NO.** The serialized transaction checks `generation > pendingGeneration`; `gen = 5` is rejected as `StaleRelativeToPending`.
2. **Who owns read + evaluate + mutation?**
   `PeerIdentityRepository` inside a single `BEGIN IMMEDIATE` write transaction.
3. **Can approval promote a candidate different from the one the user reviewed?**
   **NO.** `approvePendingRotation` requires exact matching of `expectedPendingGeneration` and `expectedPendingStaticDhPublicKey`.
4. **If the pending candidate changes before approval?**
   Returns `StaleCandidate` without promoting anything.
5. **Can a valid higher generation be discarded and old READY silently resumed?**
   **NO.** Valid higher-generation certificates are signed by the Ed25519 root; resuming an older key destroys rollback protection.
6. **What does rejecting the identity do?**
   Transitions `trustLevel = REVOKED`, clears pending fields to `NULL`, and sets resolver to `null`.
7. **Can REVOKED and KEY_CHANGED_QUARANTINED be simultaneous effective states?**
   **NO.** Canonical precedence and schema invariants ensure a revoked identity has `NULL` pending fields and is strictly `REVOKED`.
8. **Can a revoked peer create a new pending rotation?**
   **NO.** Inbound bindings for revoked peers return `Rejected(Revoked)` without modifying store state.
9. **Where does this node's outbound binding generation come from?**
   From `LocalIdentityBindingState`. Production binding issuance never accepts caller-supplied generations.
10. **What generation do legacy existing identities migrate to?**
    `generation = 0`, exactly once.
11. **Can generation wrap?**
    **NO.** Counter reaching `UINT32_MAX` fails closed on future rotation attempts; `UINT32_MAX -> 0` is forbidden.
12. **Does C8.1 have to implement local static rotation UI?**
    **NO.** C8.1 implements generation ownership and remote rotation trust policy; local rotation commands remain for a future phase.
13. **Can peer trust schema modify the frozen C7 delivery/store schema?**
    **NO.** `PeerIdentityStore` is a physically and logically distinct database.
14. **Does deleting iOS local identity keys erase the peer graph?**
    **NO.** The peer database is a separate SQLite file and must be explicitly removed by `deleteArtifacts`.
15. **Does a quarantined responder receive initiator HS3?**
    **NO.** The initiator evaluates HS2 before emitting HS3; quarantined responders receive no HS3.

---

## 24. Future Implementation Acceptance Matrix & Race Test Architecture (Phase C8.1 Target)

### 24.1 Real-SQL Concurrency Test Architecture
Concurrency tests in C8.1 MUST execute against the production `PeerIdentityRepository` backed by real on-disk SQLite / SQLCipher databases. In-memory fakes or arbitrary thread sleeps are strictly forbidden; tests must use deterministic synchronization barriers/latches to test the transaction boundary directly under contention.

### 24.2 Acceptance Test Matrix

| Category | Test Case | Expected Result |
|---|---|---|
| **Vectors** | Serialization / Deserialization KAT | Exact byte-for-byte agreement on 133-byte structure. |
| **Vectors** | Signature Preimage KAT | Exact byte-for-byte agreement on 80-byte `GMP2-IDBIND` preimage. |
| **Vectors** | `node_id` Derivation KAT | Exact `BLAKE2s-128` output matching test fixtures. |
| **Handshake** | Noise Handshake Message Sizes | HS1: 32 bytes; HS2: 229 bytes; HS3: 197 bytes. |
| **Validation** | Truncated payload (<133 bytes) | Rejected (`SECURITY_REJECT`). |
| **Validation** | Invalid version (`!= 0x01`) | Rejected (`SECURITY_REJECT`). |
| **Validation** | Corrupted signature (1 bit flip) | Rejected (`SECURITY_REJECT`). |
| **Validation** | Mismatched signing public key | Rejected (`SECURITY_REJECT`). |
| **Validation** | `binding.staticDhKey != remoteStaticKey` | Rejected (`SECURITY_REJECT`). |
| **Validation** | `first4(nodeId) != advertisedHint` | Rejected (`SECURITY_REJECT`). |
| **Trust Policy** | First encounter (`gen = 0`) | Accepted $\to$ Persisted as `TOFU_PINNED`. |
| **Trust Policy** | First encounter (`gen = 7`) | Accepted $\to$ Persisted as `TOFU_PINNED` at generation 7. |
| **Trust Policy** | Known peer same gen + same static | Accepted $\to$ Transitions to `READY`. |
| **Trust Policy** | Known peer lower gen | Rejected (rollback) $\to$ Disconnect. |
| **Trust Policy** | Known peer same gen + different static | Rejected (conflict) $\to$ Disconnect. |
| **Trust Policy** | Known peer higher gen + SAME static | Rejected (noncanonical advance) $\to$ Disconnect. |
| **Trust Policy** | Known peer higher gen + new static | Quarantined $\to$ Pending candidate persisted, accepted unchanged, resolver null, no `READY`. |
| **Trust Policy** | Pending exact candidate reconnect | Quarantined $\to$ Idempotent re-encounter, no `READY`. |
| **Trust Policy** | Pending + old accepted reconnect | Quarantined $\to$ Do not clear pending, no `READY`. |
| **Trust Policy** | Pending + intermediate gen | Rejected (stale relative to high-water mark) $\to$ Disconnect. |
| **Trust Policy** | Pending same gen + different static | Rejected (pending conflict) $\to$ Disconnect. |
| **Trust Policy** | Pending newer valid gen + new key | Quarantined $\to$ Pending candidate advances, accepted unchanged. |
| **Trust Policy** | Node ID collision with different signing pub | Rejected (`NODE_ID_SIGNING_KEY_COLLISION`) $\to$ Disconnect. |
| **Concurrency** | Concurrent identical first-seen | One `FirstSeenPinned`, one `Accepted`, single durable row. |
| **Concurrency** | Concurrent node-id collision | One row authority, loser rejected, no last-writer-wins. |
| **Concurrency** | Concurrent pending gen5 and gen6 | Final state pending gen6/K6, never regresses to gen5. |
| **Concurrency** | Concurrent duplicate pending candidate | Idempotent quarantine. |
| **Approval** | Approve exact candidate (matching gen & key) | Promoted atomically, pending cleared, trustLevel preserved. |
| **Approval** | Candidate changed before approval (gen5 reviewed, gen6 stored) | Returns `StaleCandidate`, nothing promoted. |
| **Approval** | Approve with no pending candidate | Returns `NoPendingCandidate`. |
| **Approval** | Approve when identity is revoked | Returns `RejectedRevoked`. |
| **Revocation** | Revoke quarantined identity | `trustLevel = REVOKED`, pending cleared, resolver returns `null`. |
| **Revocation** | Inbound valid binding after revocation | Returns `Rejected(Revoked)`, no store mutation. |
| **Local Gen** | Legacy identity missing generation | Migrated to `generation = 0` once. |
| **Local Gen** | Post-migration missing generation | Fails closed as corrupt. |
| **Local Gen** | Generation overflow (`UINT32_MAX`) | Fails closed on future rotation, no wrap. |
| **Resolver** | Active TOFU + no pending | Returns correct Ed25519 public key. |
| **Resolver** | Active USER_VERIFIED + no pending | Returns correct Ed25519 public key. |
| **Resolver** | Any pending rotation exists | Returns `null`. |
| **Resolver** | Revoked identity | Returns `null`. |
| **Sequencing** | Initiator invalid HS2 binding | HS3 MUST NOT be emitted $\to$ Disconnect. |
| **Sequencing** | Initiator quarantined HS2 binding | HS3 MUST NOT be emitted $\to$ Quarantine recorded. |
| **Sequencing** | Initiator valid first-seen HS2 | HS3 emitted $\to$ Handshake completes. |
| **Driver API** | iOS HS2 inspection | Proves HS2 can be read and inspected before HS3 write. |
| **Driver API** | Android remote static | Authenticated remote static available after HS2 read before `SPLIT`. |
| **Panic Wipe** | PeerIdentityStore wipe | Store deleted during wipe; crash-resume idempotency holds. |
| **Link Gate** | Inbound `FrameV2` before `READY` | Rejected / Discarded. |
