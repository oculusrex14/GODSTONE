# ADR-003 — Identity binding, TOFU, contacts, sealed sender

**STATUS: OPEN.** The A2 and A7 threat-model claims are unsupported until it closes.

## Why the current construction cannot be shipped as specified

`SealedSender.kt` exists on Android only, is called by nothing, and does not
implement the documented construction:

| PROTOCOL.md §6 | SealedSender.kt |
|---|---|
| two layers (`inner` under `K_e2e`, then sealed) | one AEAD pass |
| `HKDF` | `BLAKE2s(shared ‖ label)` |
| ChaCha20-Poly1305 | AES-GCM |
| — | sender id is **unauthenticated**: any sender can place any 16 bytes inside |

No associated data binds the routing tag, frame type, message id, version or TTL
to the ciphertext. There is no forward secrecy against later compromise of the
recipient's static key: recorded ephemerals plus that key recover past sealing
keys. "X3DH-style" should not be claimed without signed and one-time prekeys.

## The binding nobody has specified

`node_id` derives from the **Ed25519** identity key. Noise authenticates an
**X25519** static key. Nothing cryptographically binds the two, so an
authenticated handshake proves nothing about the claimed `node_id`. TOFU
pinning, QR verification and the key-change warning are all specified and none
are implemented.

## Decide before writing code

Sender authentication or deliberate sender anonymity; behaviour under sender vs
recipient compromise; deniability; offline prekeys; group messaging; exactly
which header metadata leaks.

---

## Addendum — what bitchat does, and what happened to it

[bitchat](https://github.com/permissionlesstech/bitchat) holds the same two key
pairs GODSTONE does, and resolves the binding question by **choosing the other
key as the identity**:

> a Curve25519 static key for Noise key agreement — its SHA-256 fingerprint is
> the peer's stable identity — and an Ed25519 signing key for packet signatures.

So `identity = H(X25519_static_pub)`: the identity is derived from the key that
Noise actually authenticates. A completed handshake then proves the peer's
identity **directly**, with nothing left to bind.

GODSTONE made the opposite choice. `PROTOCOL.md` §2 specifies
`node_id = BLAKE2s-128(identity_pub)` over the **Ed25519** key, while Noise
authenticates the **X25519** key — so an authenticated handshake proves nothing
about the claimed `node_id`, and the gap has to be closed by an explicit binding
nobody has specified.

Note what this means for the V3 history: iOS deriving `node_id` from the X25519
key was recorded as a defect against `PROTOCOL.md:49`. It was a genuine
*divergence* — the two platforms disagreed, which is fatal — but **iOS had
accidentally implemented the better design.** The fix aligned both platforms onto
the harder option.

**Recommended direction:** invert it. `node_id = H(static_dh_pub)` truncated to
16 bytes, and carry the Ed25519 signing key inside a self-signed announcement
bound to that static key. This is also what ADR-007 needs, since it changes the
hash anyway.

### The caution that comes with it

bitchat adopting this design did **not** make it immune. Within days of launch,
Alex Radocea demonstrated impersonation against its `Favorites` system —
described as *"broken identity authentication/verification"*, letting an attacker
intercept an identity-key/peer-id pair and appear as a trusted contact. The
project has since shipped `Pin announce signing keys to stop mesh identity
spoofing (#1349)`, which is the announcement-binding problem above, found the
hard way.

**Conclusion for GODSTONE:** the fingerprint-of-the-Noise-key model is the right
base, and it is *not sufficient on its own*. The binding between the static key,
the signing key and the displayed contact must be specified and tested, or the
same class of impersonation is available here. ADR-003 remains the highest-risk
OPEN decision in the project — it is the one that broke, in public, in the
closest comparable system.
