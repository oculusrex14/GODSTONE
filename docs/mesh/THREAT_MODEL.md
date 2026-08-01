# Godstone Mesh — Threat Model

**V4 implementation status:** threat goals, not current guarantees. The radio
stack is disabled. A2/A7 depend on open ADR-003; A6 depends on open ADR-004;
SOS authenticity/lifecycle depends on ADR-005; bulk transport depends on
ADR-006. Statements below describe the intended mitigations after those ADRs
are implemented and verified. The Archive/Oracle C1-C3 controls are separate.

## Adversaries considered

**A1 Passive local eavesdropper.** Radio receiver in range, records everything.
Mitigation: all traffic after handshake is encrypted. Sealed sender hides sender
and recipient from anyone but the recipient. Daily-rotating routing tags prevent
long-term linkage.

**A2 Malicious relay.** Runs a modified client, participates fully in the mesh.
Can drop, delay and count messages; cannot read, alter or attribute them. Frame
integrity is protected by Poly1305 under a key it does not have. Dropping is
mitigated by epidemic replication over multiple carriers.

**A3 Active injector.** Forges or replays frames. Mitigation: Noise mutual
authentication means an unauthenticated peer cannot inject into a session; nonce
counters and the msg_id seen-cache defeat replay; sealed payloads fail
authentication if altered.

**A4 Impersonator.** Claims another user's identity. Mitigation: node_id is
derived from the public identity key, so claiming an identity requires the private
key. TOFU pinning plus optional QR verification surfaces substitution attempts.

**A5 Flooder / battery attacker.** Attempts to drain devices. Mitigation: proof of
work, token-bucket rate limits, trust scoring with exponential backoff, hard
storage caps, and duty-cycle floors that the mesh cannot be forced below.

**A6 Device seizure.** Adversary physically takes an unlocked or locked device.
Mitigation: message store encrypted with a key in the Keystore or Secure Enclave;
panic wipe erases keys and history and regenerates identity; no cloud backup of
mesh data; contact list stored encrypted.

**A7 Local traffic analysis.** Correlates who transmits when and where.
Partial mitigation only: rotating tags, padding to fixed size buckets (256, 512,
2048, 8192 bytes) and randomised transmission jitter. Full defence is impossible
at the application layer with commodity radios, and we say so plainly rather than
implying protection we cannot deliver.

## Explicitly out of scope

* A global passive adversary observing all radio everywhere.
* Physical coercion of the device holder.
* Compromised OS, bootloader or baseband.
* Deliberate radio jamming. The app detects sustained interference and tells the
  user, but cannot defeat it.

## Honest limitations shown in the UI

Users making life-and-death decisions deserve accurate expectations:

1. Range is roughly 30–100 m per hop for BLE, more in open ground, far less
   through reinforced concrete.
2. Delivery is best effort with no guarantee and no timeline. A message may take
   hours if it waits for a carrier to physically move.
3. iOS in the background is materially weaker than Android; the UI states this.
4. The mesh reveals that *someone nearby is transmitting*. In an environment where
   emitting any signal is dangerous, the app offers a Silent Mode that receives
   only and never transmits.
