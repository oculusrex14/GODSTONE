# Godstone V4 — Open Audit Register

This register records unresolved risks after applying the V4 repair change-set.
A finding is closed only by executable evidence against the shipping path.
Accepted ADRs are decisions, not implementations.

## P0 — stop-ship

| ID | Finding | Required closure evidence |
|---|---|---|
| A-01 | Android and iOS mesh runtimes are not on one canonical frame path | both routers/stores use generated GMP/2.1; golden and cross-device round trip |
| A-02 | BLE record layer and Noise handshake driver are not implemented | ADR-002 property tests plus Android↔iOS Hardware Case 0 |
| A-03 | Mesh/SOS has no durable, authenticated end-to-end delivery lifecycle | persist-before-send, recipient ACK, expiry/cancel semantics, restart tests |
| A-04 | iOS has no durable encrypted DTN store or coordinated panic wipe | reboot/jetsam/migration/seizure and wipe recovery tests |
| A-05 | Identity binding/TOFU/contact and sealed sender are unresolved | ADR-003 accepted and cryptographically verified implementation |
| A-06 | External Noise vectors remain unpinned | independent vectors consumed by both platform tests; no `--allow-unpinned` |
| A-07 | Mobile targets have not been compiled from this final markdown in the assembly environment | clean Gradle and Xcode logs attached to the revision |
| A-08 | Corpus is three unreviewed examples, not a survival archive | licensed corpus, per-chunk provenance and clinician/editorial approval |
| A-09 | Native model dependency and weights are not reproducibly pinned | immutable dependency revision, hashes, licences, offline build proof |

## P1 — required before beta

| ID | Finding | Required closure evidence |
|---|---|---|
| A-10 | Android store migration, key durability, cap enforcement and corruption recovery are incomplete | migration matrix, power-loss and all-SOS flood tests |
| A-11 | Runtime permission/capability lifecycle is incomplete | denied/revoked/off/unsupported tests on supported OS versions |
| A-12 | Archive integrity and fallback UX require device tests | corrupt/missing DB tests with readable degraded mode |
| A-13 | Android semantic search is lexical-only because `nativeEmbed` is absent | one pinned embedding model/space and port parity tests |
| A-14 | Bulk plane is disabled and former stubs could report success without bytes | ADR-006 accepted and encrypted cross-platform transfer tests |
| A-15 | Battery and background behavior are unmeasured | radios/model/storage profiling under normal, low and critical battery |
| A-16 | Accessibility and stress UX have no instrumentation/device evidence | TalkBack/VoiceOver, dynamic type, contrast, glove/one-hand tests |
| A-17 | Static integration control cannot prove live reachability through dead branches | compiler/call-graph coverage or end-to-end tests for critical paths |
| A-18 | Store/privacy/disclaimer documents describe surfaces not yet implemented | in-app surfaces verified in release UI |

## Closed by V4

- V3 pseudo-patches replaced by complete file bodies.
- Duplicate V4 paths rejected during assembly.
- Android split composition root removed.
- Known V3 Android/iOS compile blockers corrected in source.
- iOS Noise message construction/parser/nonce defects corrected.
- Swift grounding IDF equation aligned with Python/Kotlin.
- SQLCipher package path corrected and initialization moved before helper use.
- Placeholder Archive screens replaced with real repositories.
- Unsafe radio, SOS and bulk claims fail closed.
- Platform-port BLAKE2s and Noise message-size tests added.
- Mutation controls document their one remaining text-analysis ceiling.

## Rule for future reviews

For every proposed closure, require all four:

1. exact shipping call site;
2. negative control that fails when the defect is reintroduced;
3. platform compile/test evidence;
4. user-visible claim no stronger than the measured result.
