# Status accounting — AUDIT-003-R1 (refreshed)

Derived from `REMEDIATION_STATE.json`, `EXTERNAL_BLOCKERS.json` and `TASKS.json`. Nothing here is new
evidence; it is the classes the remediation requireth to be stated plainly.

## 1. Submitted and awaiting INDEPENDENT verification — 18

16 `FIX_SUBMITTED` and 2 `PARTIAL`. Only an independent audit may write `VERIFIED_FIXED`, and this work
never writes it (the ledger court refuseth it).

- `GS-ARCHIVE-001` — Archive runtime accepts usable bytes without the required trusted mani (FIX_SUBMITTED)
- `GS-ARCHIVE-002` — Android admits malformed archive schema and reports SQL read failures  (FIX_SUBMITTED)
- `GS-ARCHIVE-003` — Android search results cannot open the full document and NoResults is  (FIX_SUBMITTED)
- `GS-ARCHIVE-004` — The iOS full-document reader has no scrolling container (FIX_SUBMITTED)
- `GS-ARCHIVE-005` — Archive navigation bypasses selection metadata and persistence helpers (PARTIAL)
- `GS-CONTENT-001` — Final chunk approvals are optional in release builds, and the approved (FIX_SUBMITTED)
- `GS-CONTENT-002` — Archive bytes and their receipts are published separately, producing m (FIX_SUBMITTED)
- `GS-CONTENT-003` — The default release validation/check-only path still accepts a signing (FIX_SUBMITTED)
- `GS-CTRL-001` — Completion validator accepts failed commands, missing logs, and eviden (FIX_SUBMITTED)
- `GS-CTRL-002` — Readiness controls already fail on the audited task sequence (FIX_SUBMITTED)
- `GS-DIAG-001` — Diagnostics retain an unbounded map of historic relation keys (FIX_SUBMITTED)
- `GS-GATE-001` — Release gate validation can bypass exact-SHA and executor evidence thr (FIX_SUBMITTED)
- `GS-MODEL-001` — Runtime model staging and loading can omit all provenance verification (FIX_SUBMITTED)
- `GS-PACKAGE-001` — The iOS artifact inspector accepts prohibited signed entitlements and  (FIX_SUBMITTED)
- `GS-PACKAGE-002` — The Android artifact inspector validates AAB names but not its native  (FIX_SUBMITTED)
- `GS-STORE-001` — T29 proves a fake SQLCipher classifier, not the actual Android store (FIX_SUBMITTED)
- `GS-STORE-002` — iOS private stores still use ordinary SQLite without a store DEK (PARTIAL)
- `GS-SUPPLY-001` — Offline cache restore accepts traversal names and symlink sources (FIX_SUBMITTED)

## 2. Red captured, repair OWED — 1 open findings carry a recorded red

- `GS-STORE-003` — red recorded, repair owed

## 3. External artifacts

Every blocker's `closure_evidence` is **NULL** (A06, APPROVED_CONTENT, NATIVE_MODELS, HARDWARE, SIGNING). Acquisition turneth NOTHING green, no fixture ever
substituteth for an approval, and the requests stand in `EXTERNAL_INPUT_REQUESTS.md`.

## 4. Closure evidence made STALE by a production owner change — 12 submitted findings

Each changed production owner code, so any earlier closure evidence for its dependents is stale until
revalidated -- including the builder's own historic task evidence, and including mine the moment the next
repair toucheth the same owner.

## 5. Proven NOWHERE in this work

- **No hosted lane**: every result is a LOCAL reproduction of the constituent commands.
- **No device**: no emulator, simulator, phone, radio or clinical evaluation.
- **No independent verification**: not one finding is `VERIFIED_FIXED`.
- **Final convergence (T78) has NOT run**: no single clean exact candidate SHA carrieth fresh green
  canonical AND hosted controls; LIGHT Archive and Mesh/Oracle are both NO-GO.
- **Readiness is FALSE** and the five external gates are OPEN or BLOCKED.
