# ADR-007 — Noise cipher suite: BLAKE2s → SHA-256

**STATUS: OPEN, with a strong recommendation and a measured case.**
Opened after reading [bitchat](https://github.com/permissionlesstech/bitchat),
which ships the SHA-256 variant on both platforms.

---

## 1. The recommendation

**Adopt `Noise_XX_25519_ChaChaPoly_SHA256` and delete every hand-rolled
cryptographic primitive in the iOS tree.**

This closes audit **A-02** — recorded since V1 as *"the largest single piece of
technical debt in the repository"* — not by patching the hand-rolled code, but by
removing the reason it exists.

---

## 2. Why A-02 has never closed

`docs/AUDIT.md` A-02 reads PARTIAL and has for three revisions:

> Hand-rolled BLAKE2s under Noise. Patching three known bugs leaves the unknown
> ones. The right end state is one cacophony-verified core shared by both
> platforms.

The stated end state — a shared verified core via JNI/FFI — is a large piece of
work nobody has started, so the debt has simply persisted. **It persisted because
the exit was framed as "make the hand-rolled code trustworthy" when the available
exit was "stop needing it".**

BLAKE2s is the only primitive in the stack that iOS does not provide:

| primitive | iOS | Android |
|---|---|---|
| SHA-256 | `CryptoKit.SHA256` | `MessageDigest` |
| HMAC-SHA256 | `CryptoKit.HMAC<SHA256>` | `javax.crypto.Mac` |
| HKDF-SHA256 | `CryptoKit.HKDF` (iOS 14+) | BouncyCastle |
| ChaCha20-Poly1305 | `CryptoKit.ChaChaPoly` | BouncyCastle / noise-java |
| X25519 | `CryptoKit.Curve25519.KeyAgreement` | BouncyCastle |
| Ed25519 | `CryptoKit.Curve25519.Signing` | BouncyCastle |
| **BLAKE2s** | **absent — hand-rolled, 169 lines** | BouncyCastle `Blake2sDigest` |

Everything else was already composed rather than invented, exactly as C6
requires. BLAKE2s is the single exception, and it is the reason
`Blake2s.swift` (169 lines) and `Hkdf.swift` (77 lines, HMAC built by hand on top
of it) exist at all.

**246 lines of hand-written cryptography, all of it downstream of one choice.**

---

## 3. Measured: the change is a parameter, not a rewrite

Run against `crypto/noise_ref.py` with only the hash function swapped:

```
BLAKE2s (current)          SHA256 (bitchat suite)
  sizes      [32, 96, 64]    sizes      [32, 96, 64]
  keys agree True            keys agree True
  hash       e739642d...     hash       6220bbb1...

same message sizes  : True
different transcript: True
```

Noise is parameterised over `HASHLEN = 32`; both hashes are 32 bytes, so nothing
structural moves. The reference implementation ran both suites **unchanged** —
one lambda substitution and a protocol-name string.

The wire format is untouched: `[32, 96, 64]` either way. Only the transcript
differs, which means vectors must be re-pinned and nothing else.

---

## 4. bitchat is the existence proof

bitchat ships `Noise_XX_25519_ChaChaPoly_SHA256` on iOS **and** Android, with the
two implementations protocol-compatible in production. Its iOS Noise layer is
CryptoKit throughout. That is not a design argument, it is a deployed system
doing exactly what this ADR proposes, at ~34k stars and v1.7.1 on the App Store.

The Noise specification lists SHA256, SHA512, BLAKE2s and BLAKE2b as standard
hashes. All four are conformant. **The choice between them is availability, not
security**, and on iOS that decides itself.

---

## 5. Blast radius

17 files reference BLAKE2s. The Noise hash is not the only use:

| use | current | after |
|---|---|---|
| Noise hash / HKDF | BLAKE2s-256 | SHA-256 |
| `node_id` | BLAKE2s-128(pub) | SHA-256(pub) truncated to 16 B |
| bloom index | BLAKE2s-64 | SHA-256 truncated to 8 B |
| proof of work | BLAKE2s-256 partial preimage | SHA-256 partial preimage |
| sealed sender KDF | BLAKE2s(shared ‖ label) | HKDF-SHA256 (ADR-003 rewrites this anyway) |

All of these are hash-to-identity or hash-to-index uses where SHA-256 is at least
as strong. Truncating SHA-256 to 128 or 64 bits is standard and is what bitchat
does for its own fingerprint.

**Android keeps working either way** — BouncyCastle has both. The migration is
driven entirely by iOS, and both platforms must move together or the mesh
partitions.

### Files deleted

```
ios/Godstone/Sources/GodstoneCore/Blake2s.swift   169 lines
ios/Godstone/Sources/GodstoneCore/Hkdf.swift       77 lines
                                                  ---
                                                  246 lines of hand-rolled crypto
```

`Hkdf.swift` goes because Noise's HKDF is HMAC-based and `CryptoKit.HMAC<SHA256>`
provides it directly. Note that `Hkdf.split` was **already found defective once**
(it returned `temp_key` as the chaining key and fed `material‖0x01` instead of
`0x01`, diverging at the first `MixKey`). That is one confirmed bug in 77 lines
of hand-written key derivation — precisely the argument for deleting the file
rather than auditing it again.

---

## 6. The counter-argument, stated fairly

**BLAKE2s is faster than SHA-256 in software**, and on a battery-constrained mesh
(C4) that is not nothing. Rough figures: BLAKE2s ≈ 1.5–2× SHA-256 on ARM without
hardware acceleration.

**Rejected, for two reasons.** First, every ARMv8 core GODSTONE targets has
SHA-256 instructions (`SHA256H`, `SHA256H2`), so on real hardware SHA-256 is
typically *faster*, and CryptoKit uses them. Second, and decisively: the hashing
cost of a handshake is a few microseconds against a BLE connection setup measured
in hundreds of milliseconds. **This has never been the power bottleneck.** Duty
cycling is, which is why `PROTOCOL.md` §3.1 spends its effort there.

Trading a measured 246 lines of unverified hand-written cryptography for a
theoretical microsecond is not a trade.

---

## 7. Cost

The migration invalidates every pinned vector. `crypto/gen_vectors.py` must
regenerate, `handshake_vectors.json` changes wholesale, and Invariant D re-pins —
**in the same commit**, or the negative controls are meaningless.

It also changes `node_id`, therefore `node_hint`, therefore the Noise prologue.
ADR-001 §7 already requires a prologue change (`GMP1` → `GMP2`), so **these two
migrations should land together** rather than invalidating the vectors twice.

External conformance improves: SHA-256 Noise vectors are far more widely
published than BLAKE2s ones, so `docs/PINNING_CACOPHONY.md` gets easier, not
harder.

---

## 8. Decision required

1. Accept the suite change, or record why the hand-rolled path is preferred.
2. If accepted, sequence it **with** ADR-001's prologue change — one vector
   re-pin, not two.
3. Update C6's status. It currently reads *"partially true — A-02 stands, and
   that is the largest single piece of technical debt."* After this, C6 is
   simply true, which would be the first constraint to move from partial to
   satisfied since V1.

## 9. Acceptance criteria

- [ ] `Blake2s.swift` and `Hkdf.swift` deleted; no hand-rolled primitive remains
- [ ] iOS Noise stack is CryptoKit only
- [ ] vectors regenerated and Invariant D re-pinned in the same commit
- [ ] both platforms reproduce the new transcript
- [ ] A-02 and A-03 closed in `docs/AUDIT.md` with the evidence linked
- [ ] `ci/integration.py` gains a check that no hand-rolled hash reappears
