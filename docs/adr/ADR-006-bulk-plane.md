# ADR-006 — The bulk transfer plane

**STATUS: OPEN, with a recommended direction.**
Opened in response to GPT P1-08 and to a concrete external reference:
[LocalSend](https://github.com/localsend/localsend).

---

## 1. Why this ADR exists

The V3 bulk transports were non-functional: Android returned success without
transmitting bytes, while iOS destroyed peer identity at the callback boundary
and bypassed the Noise session. V4 removes those false-success paths. Both
platform implementations now report unavailable and return failure.

That is a safety closure, not a bulk implementation. The architectural question
remains: Wi-Fi Aware is Android-specific and MultipeerConnectivity is
Apple-specific, so they cannot form one Android↔iOS transport.

GPT's challenge was the right one: *"Evaluate whether Wi-Fi Aware and
MultipeerConnectivity can actually interoperate cross-platform. If not, redesign
the bulk plane rather than treating two platform-specific technologies as one
shared transport."*

**They do not interoperate.** Wi-Fi Aware (NAN) is an Android API with no iOS
client; MultipeerConnectivity is Apple-only and has no Android implementation.
`PROTOCOL.md` §3.2 lists them side by side under one heading, which reads as a
single bulk plane and is in fact two disjoint ones. Android↔iOS bulk transfer
has never been possible, and no amount of fixing either stub changes that.

---

## 2. What LocalSend demonstrates

LocalSend is a cross-platform local file-transfer app (Android, iOS, Windows,
macOS, Linux) that solves the *adjacent* problem and is worth reading carefully.
Its architecture, from the protocol repository:

| | LocalSend |
|---|---|
| discovery | multicast UDP to `224.0.0.167:53317`, announce/response |
| fallback | HTTP scan of the local subnet when multicast is filtered |
| transfer | REST over HTTP/HTTPS, TCP 53317 |
| encryption | TLS with a certificate generated **on device** |
| identity | fingerprint = SHA-256 of the TLS certificate |
| servers | none |

Three things transfer directly to this project:

**(a) One transport, both platforms.** LocalSend does not pair Wi-Fi Aware with
MultipeerConnectivity. It picks an IP-layer transport that every platform can
speak and implements it once. That is the structural answer to GPT's question,
and it is validated by a shipping application rather than by reasoning.

**(b) Certificate-fingerprint identity is a working TOFU model.** LocalSend's
fingerprint — a hash of a self-generated cert — is the same shape as the static
key pinning ADR-003 must specify. Useful precedent for a mesh with no directory.

**(c) A protocol repository separate from the implementation.** `localsend/protocol`
is versioned independently, with `v1.md` and `v2.md` as normative documents. That
is exactly the discipline ADR-001 requires and exactly what this repository has
lacked: `PROTOCOL.md` drifted from the code until the code contradicted it in
four places.

### What does NOT transfer

**LocalSend requires an existing IP network.** It assumes a router, a subnet, and
devices with addresses on it. GODSTONE's entire premise is the hours and days
*after* that infrastructure fails. LocalSend is not a mesh, does no multi-hop
routing, has no store-and-forward, and would find zero peers in a blackout.

**It is therefore not a candidate to replace the BLE control plane**, and adopting
it wholesale would delete the product's reason to exist. The relevance is bounded
and specific: it is evidence about *the bulk plane*, and a model for *protocol
discipline*.

---

## 3. Recommended direction

Establish an IP link ourselves, then run a documented HTTP-shaped protocol over
it — the LocalSend pattern, minus the assumption that the network already exists.

```
1. BLE control plane establishes a Noise session          (ADR-002)
2. Both peers advertise BULK_CAPABLE
3. Payload exceeds BULK_THRESHOLD (512 B)
4. Over the ESTABLISHED BLE session, negotiate a link:
       Android: Wi-Fi Direct group owner / local-only hotspot
       iOS:     joins as client
   The SSID, PSK and expected TLS fingerprint are exchanged INSIDE the
   Noise session, so the bulk link is authenticated by the BLE handshake
   before its first byte -- no second trust decision, no second handshake.
5. Transfer over TLS on the link-local address, chunked, resumable, hashed
6. Tear the link down within 5 s of the last byte
```

The critical property is step 4: the bulk peer is bound to the BLE-authenticated
static key. V3's iOS bulk transport accepted every MultipeerConnectivity
invitation and generated a random `UUID()` per callback, so a bulk peer could be
substituted independently of the mesh identity entirely.

---

## 4. The constraint this collides with — decide before implementing

C1 says **no network**. `ci/check_parity.py` Invariant E enforces it by grepping
iOS sources for `URLSession|NSURLConnection|CFStream|Network.framework` and
failing the build on a match.

**A LocalSend-style bulk plane needs sockets and a local HTTP server, and would
trip that gate immediately.** This is not a reason to reject the direction; it is
a sign that C1 is stated imprecisely. What C1 actually protects is: *no contact
with any server, no internet egress, no telemetry, nothing that works only when
infrastructure exists*. A link-local TLS socket to a peer 10 metres away over a
hotspot we created ourselves violates none of that.

**Required before any code:** amend C1 to distinguish *internet egress* from
*link-local peer transport*, and make the distinction **enforceable** rather than
rhetorical. Candidate mechanism: allow socket APIs only within a designated
module, and have Invariant E assert that (a) no default-route address is ever
constructed, (b) no DNS resolution occurs, (c) the Android manifest still
declares no `INTERNET` permission — which by itself already makes internet egress
impossible on that platform, and is a far stronger control than a grep for
`URLSession`.

Until C1 is amended, **do not implement this.** Shipping a networking stack that
contradicts a constraint the CI enforces would be the same category of defect as
everything else in `docs/AUDIT.md`: the claim and the code disagreeing.

---

## 5. Decision to be made

1. Amend C1 as above, or reject the direction and accept that bulk transfer is
   Android↔Android and iOS↔iOS only, permanently, and say so in the UI.
2. If amended: specify the link negotiation, the chunk/ACK/resume protocol, the
   integrity hash, and the idle teardown — as a normative document, versioned
   separately, in the LocalSend style.
3. Keep both implementations fail-closed until the selected shared protocol
   passes the acceptance criteria. A method must never report success without a
   verified write.

## 6. Acceptance criteria

- [ ] a payload > 512 B transfers Android↔iOS, interrupted and resumed, hash verified
- [ ] the bulk peer is provably bound to the BLE-authenticated static key
- [ ] no bulk peer can be substituted independently of the mesh session
- [ ] the link is torn down within 5 s of the last byte, verified by radio state
- [ ] C1 remains enforceable, with internet egress still structurally impossible
