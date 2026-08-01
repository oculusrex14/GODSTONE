# Godstone V4 — Build and Verification Report

**Date:** 1 August 2026  
**Milestone:** compile repair, one composition root, honest CI, accepted wire/link ADRs  
**Release status:** **PRE-ALPHA / NOT SHIPPABLE**

## 1. Executive result

V4 consolidates the V3 source and both adversarial reviews into a self-applying
change-set. It fixes confirmed source defects, adds platform-port tests, removes
placeholder product surfaces, and disables network-like features whose security
or delivery semantics are not yet implemented.

V4 does **not** claim production readiness or cross-platform mesh operation.
ADR-001 and ADR-002 are accepted designs; their M1-wire and M2-link
implementations remain open. Both mobile apps therefore expose the mesh as
unavailable rather than transmitting plaintext or reporting fictional delivery.

## 2. Closed in source

| Area | V4 action |
|---|---|
| Change-set packaging | complete target files only; duplicate paths rejected; no inert pseudo-patches |
| Android composition | deleted `MeshNodeHolder`; service, app and UI share the Hilt singleton |
| iOS compile blockers | declared session/peer state, protocol conformance and FrameV2 router surface |
| Android compile blockers | corrected SQLCipher API, SafetyGate call, BuildConfig fields and Kotlin Compose plugin |
| Noise port | rewrote iOS XX transcript processing and added Android/iOS message-size tests |
| Grounding parity | corrected Swift IDF precedence and hardened integration checks |
| Archive UI | replaced Android/iOS placeholders with real SQLite-backed document browsing |
| Truthful failure | radio, SOS and bulk UI fail closed until implementations pass acceptance tests |
| CI controls | comment-stripping reachability checks plus mutation corpus; 5/6 caught, one documented static-analysis ceiling |
| Wire schema | accepted GMP/2.1, widened priority mask and regenerated both codecs/golden vectors |

## 3. Verification performed in the assembly environment

The final change-set is applied to a clean V3 extraction before these checks are
run. Results recorded by the final assembly script:

- marker/path uniqueness and byte-for-byte reconstruction;
- tier-table parity;
- MEDIUM archive build without embeddings;
- wire regeneration;
- generated crypto fixtures and reference conformance;
- C3 probes and strict grounding evaluation;
- symbol resolver and integration mutation controls;
- invariants A–G;
- mesh simulator regression scenario;
- Swift parser pass over authored Swift sources where host modules permit.

The exact command log is embedded in the final V4 markdown. A Python/static pass
is not a substitute for Gradle, Xcode, radios, or clinical review.

## 4. Deliberately disabled

| Capability | Why disabled | Re-enable gate |
|---|---|---|
| BLE mesh | canonical v2 runtime and record/handshake driver not complete | ADR-001 M1 + ADR-002 M2 acceptance tests |
| SOS transmission | no durable end-to-end ACK semantics or verified authenticity model | ADR-003/004/005 plus hardware tests |
| Wi-Fi/AWDL bulk | no shared authenticated cross-platform protocol | ADR-006 |
| Android semantic vector search | JNI `nativeEmbed` is absent; mixing embedding spaces is unsafe | implemented port + model lock + parity tests |
| release model download | weights/hashes are not externally verified and locked | reproducible model lockfile |

Lexical Archive search and the C3 safety gate remain available. Disabling a
partial feature is intentional C5 degradation, not a hidden failure.

## 5. Open stop-ship gates

1. Clean Android compile/test/assemble with restored wrapper and pinned native dependency.
2. Clean macOS Swift/Xcode compile/test for all targets.
3. Android↔iOS Hardware Case 0.
4. External/pinned Noise vectors and removal of `--allow-unpinned`.
5. Durable iOS store, Android migration/eviction hardening, coordinated panic wipe.
6. Identity binding, TOFU/contact model and sealed-sender redesign.
7. Permission/capability lifecycle and accessibility stress tests.
8. Pinned llama.cpp revision and model/artifact hashes.
9. Real licensed corpus with clinician/editorial approval per independently safe chunk.
10. Store/privacy/disclaimer materials implemented in the apps, not merely documented.

## 6. Honest readiness

| Dimension | V4 assessment |
|---|---:|
| Architecture decisions | 8/10 |
| Source coherence | 7/10 pending real compilers |
| Verification design | 8/10 with documented reachability ceiling |
| Mesh runtime | 1/10; intentionally disabled |
| Content readiness | 1/10; examples only |
| Production readiness | **2/10** |
