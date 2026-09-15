# Remediation handoff — AUDIT-003-R1

Ledger `REMEDIATION_STATE.json`; protocol `README.md`; external requests `EXTERNAL_INPUT_REQUESTS.md`;
accounting `STATUS_ACCOUNTING.md`; audit source `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` (READ-ONLY; its own process keepeth writing into the
original checkout, whose declared addition is GROWING with a floor that may only rise).

## Status — 18 submitted (16 FIX_SUBMITTED, 2 PARTIAL), 36 OPEN

NOT ONE finding is `VERIFIED_FIXED`: only an INDEPENDENT AUDIT may write that, and this work never writes it
(the ledger court refuseth it).

| Finding | Status | Wave | Title |
|---|---|---|---|
| GS-CTRL-001 | FIX_SUBMITTED | 1 | Completion validator accepts failed commands, missing logs |
| GS-CTRL-002 | FIX_SUBMITTED | 1 | Readiness controls already fail on the audited task sequen |
| GS-GATE-001 | FIX_SUBMITTED | 1 | Release gate validation can bypass exact-SHA and executor  |
| GS-ARCHIVE-001 | FIX_SUBMITTED | 2 | Archive runtime accepts usable bytes without the required  |
| GS-ARCHIVE-002 | FIX_SUBMITTED | 2 | Android admits malformed archive schema and reports SQL re |
| GS-ARCHIVE-003 | FIX_SUBMITTED | 2 | Android search results cannot open the full document and N |
| GS-ARCHIVE-004 | FIX_SUBMITTED | 2 | The iOS full-document reader has no scrolling container |
| GS-ARCHIVE-005 | PARTIAL | 2 | Archive navigation bypasses selection metadata and persist |
| GS-CONTENT-001 | FIX_SUBMITTED | 2 | Final chunk approvals are optional in release builds, and  |
| GS-CONTENT-002 | FIX_SUBMITTED | 2 | Archive bytes and their receipts are published separately, |
| GS-CONTENT-003 | FIX_SUBMITTED | 2 | The default release validation/check-only path still accep |
| GS-MODEL-001 | FIX_SUBMITTED | 3b | Runtime model staging and loading can omit all provenance  |
| GS-PACKAGE-001 | FIX_SUBMITTED | 3a | The iOS artifact inspector accepts prohibited signed entit |
| GS-PACKAGE-002 | FIX_SUBMITTED | 3a | The Android artifact inspector validates AAB names but not |
| GS-SUPPLY-001 | FIX_SUBMITTED | 3a | Offline cache restore accepts traversal names and symlink  |
| GS-STORE-001 | FIX_SUBMITTED | 4a | T29 proves a fake SQLCipher classifier, not the actual And |
| GS-STORE-002 | PARTIAL | 4a | iOS private stores still use ordinary SQLite without a sto |
| GS-DIAG-001 | FIX_SUBMITTED | 8 | Diagnostics retain an unbounded map of historic relation k |

## The next findings, in the queue's order

- `ANDROID-01` — The application never starts D2 or key confirmation (wave 4e, HIGH)
- `ANDROID-03` — T24 trusted publication is unused; the real consumer still recei (wave 4e, HIGH)
- `CRYPTO-001` — Session lookup and destruction still use only a peer handle, so  (wave 4b, HIGH)
- `CRYPTO-002` — Session retirement never reaches the transport authority and exp (wave 4b, HIGH)
- `CRYPTO-003` — Destroyed retained controllers and primitive sessions still repo (wave 4b, MEDIUM)
- `CRYPTO-004` — The T35 low-order-DH negative tests exercise an unused helper wh (wave 4b, HIGH)
- `CRYPTO-005` — DIRECT intent persistence is only an in-memory seam and is not c (wave 4b, HIGH)
- `CRYPTO-006` — Duplicate journal admission is treated as success for a differen (wave 4b, HIGH)
- `GS-STORE-003` — Actual message-store upgrades still drop durable tables (wave 4a, HIGH)
- `GS-STORE-004` — Receipt-relative retention is not stored or executed by the real (wave 4a, HIGH)
- `GS-STORE-005` — Total-store limits and observer cancellation are not wired (wave 4a, HIGH)
- `GS-STORE-006` — Crash-resumable wipe does not own transport drain or the new pri (wave 4a, HIGH)
- `IOS-02` — adapter never starts D2 or key confirmation (wave 4e, HIGH)
- `IOS-04` — authenticated peer publisher unwired; empty routed sender and st (wave 4e, HIGH)
- `ANDROID-06` — Whole-record reservations do not reserve capacity or enforce sin (wave 4f.1, HIGH)
- `IOS-01` — stop loses manager references before OS cleanup (wave 4c.1, HIGH)

## Every open PARTIAL, and what it still oweth

- **GS-ARCHIVE-005**: STEP 1: choose ONE real document-selection owner on iOS and route destination selection through scene.open(document:) -- the app view still drives ArchiveDocumentReader directly
- **GS-ARCHIVE-005**: STEP 2: load passages and source metadata for the SAME captured selected document identity, publishing only if that selection is still current
- **GS-ARCHIVE-005**: STEP 3: persist small navigation identities on Android through SavedStateHandle in the Hilt view model
- **GS-ARCHIVE-005**: STEP 4: persist the equivalent Codable scene record on iOS and bind it to NavigationStack
- **GS-ARCHIVE-005**: STEP 5 (second half): the return road re-fetcheth its rows -- only the IDENTITY travelleth today, and the identity is now carried
- **GS-ARCHIVE-005**: STEP 6: record REAL visible passage anchors from the scroll view and restore only after the matching document and layout exist
- **GS-STORE-002**: THE CONCRETE ENGINE: `EncryptedStoreEngine` hath NO concrete SQLCipher implementation wired into this path -- the composition can now REFUSE, but the DEVICE must inject a real engine for the stores to open at all. That engine is a NATIVE artifact and an EXTERNAL input; the host repair proveth the refusal law, not a real encrypted database.
- **GS-STORE-002**: THE DEFAULT PATH: `MeshRuntime.create` still accepteth `encryptedStores: nil` (the legacy default used by the app's own callers and by the older courts), and in that case it openeth the stores as before. Making the parameter REQUIRED would break every existing caller at once; the card's law is that ordinary SQLite may never BE a private store, so the next increment is to make the factory required at the APP's composition root (where the engine is injected) and then tighten here.
- **GS-STORE-002**: THE THIRD LIMB (the card's 'message-store protection errors remain swallowed') is asserted by W03 as a SOURCE law; its behavioural proof needeth the real engine.

## The suite that measures this work

- `tools/readiness/tests/` — the GREEN lane (the readiness suite and the adopted courts).
- `tools/readiness/audit_probes/` — the audit's own 12-case final suite: it began at SEVEN reds and is now
  FULLY GREEN, because GS-SUPPLY-001, GS-DIAG-001, GS-PACKAGE-001 and GS-PACKAGE-002 are repaired. Each
  repair MOVED its arms verbatim into the canonical lane, inheriting the AUDIT'S OWN FIXTURE.
- Red-by-design probes (Kotlin `kotlin/`, Swift `swift/`) live OUTSIDE the build lanes with their run
  recipes: a red arm inside a module reddens the lane, and the green lane must never be red.

## How to reproduce a RED reliably

1. `git worktree add --force --detach <tmp> <PRE-REPAIR COMMIT>` (an UNCOMMITTED repair's pre-repair
   product IS `HEAD`).
2. `cp android/local.properties <tmp>/android/local.properties` — a fresh worktree LACKS it and every
   Gradle command fails with "SDK location not found"; A COMPILE FAILURE IS NOT A RED.
3. Copy ONLY the court in, and write its RED arms against PRE-EXISTING API only.
4. For Swift: `python3 scripts/sync_ios_foundation_package.py` AFTER every source edit, or `swift test`
   runneth the OLD copy and reports 0 tests.
5. NEVER report a compile failure as a behavioural red.

## Standing traps (all of these have cost a round)

- A WITNESS GREEN ON BOTH REVISIONS PROVETH NOTHING. Two were produced and reverted this session
  (GS-ARCHIVE-005, GS-STORE-001); the pre-repair run is what catcheth them.
- A control that PROTECTS THE BYPASS will be found (T52's deputy arms, T61's null-artifact arm, T29's
  stub) — reverse it and record the reversal in the arm itself.
- An arm that strips COMMENTS can be blind to a charge whose evidence IS a comment (GS-STORE-001).
- A red that cannot be SATISFIED is not a red: arm A of GS-STORE-001 first forbade the only native seam a
  host court hath.
- A mutation rod over DEAD code can never be killed: delete the code, re-anchor on a LIVE guard.
- `assertRaises(ValueError)` without a NAMED reason is satisfied by an unrelated refusal.
- Gradle/Swift run EVERY test source in a module: a red arm must live outside the lane until its repair.
