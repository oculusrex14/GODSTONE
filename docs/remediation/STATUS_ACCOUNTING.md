# Status accounting — AUDIT-003-R1

Derived from `REMEDIATION_STATE.json`, `EXTERNAL_BLOCKERS.json` and `TASKS.json`. Nothing here is new
evidence; it is the three classes the remediation requireth to be stated plainly.

## 1. Submitted and awaiting INDEPENDENT verification — 14

These carrieth my `FIX_SUBMITTED` and NOTHING more. Only an independent audit may write
`VERIFIED_FIXED`, and **this work never writes it** (the ledger court refuseth it).

- `GS-ARCHIVE-001` — Archive runtime accepts usable bytes without the required trusted manifest
- `GS-ARCHIVE-002` — Android admits malformed archive schema and reports SQL read failures as emp
- `GS-ARCHIVE-003` — Android search results cannot open the full document and NoResults is not re
- `GS-ARCHIVE-004` — The iOS full-document reader has no scrolling container
- `GS-CONTENT-001` — Final chunk approvals are optional in release builds, and the approved stagi
- `GS-CONTENT-002` — Archive bytes and their receipts are published separately, producing mismatc
- `GS-CONTENT-003` — The default release validation/check-only path still accepts a signing key n
- `GS-CTRL-001` — Completion validator accepts failed commands, missing logs, and evidence-fre
- `GS-CTRL-002` — Readiness controls already fail on the audited task sequence
- `GS-DIAG-001` — Diagnostics retain an unbounded map of historic relation keys
- `GS-GATE-001` — Release gate validation can bypass exact-SHA and executor evidence through l
- `GS-PACKAGE-001` — The iOS artifact inspector accepts prohibited signed entitlements and non-iO
- `GS-PACKAGE-002` — The Android artifact inspector validates AAB names but not its native payloa
- `GS-SUPPLY-001` — Offline cache restore accepts traversal names and symlink sources

## 2. Blocked by, or awaiting, an EXTERNAL artifact — 0 submitted findings touch one

An external artifact never turneth a gate green here, no fixture ever substitute th for one, and every
blocker's `closure_evidence` is **NULL**. The requests are in `EXTERNAL_INPUT_REQUESTS.md`.

- (none)

## 3. Closure evidence made STALE by a production owner change — 11

Every submission in this list changed production owner code, so ANY earlier closure evidence for its
dependents is stale until revalidated — including the builder's own historic task evidence, and
including mine the moment the next repair touches the same owner. The named dependents are the ledger's
own `invalidated_dependents`.

- `GS-ARCHIVE-001` — 3 dependent(s) named
- `GS-ARCHIVE-002` — 3 dependent(s) named
- `GS-ARCHIVE-003` — 2 dependent(s) named
- `GS-ARCHIVE-004` — 4 dependent(s) named
- `GS-CONTENT-001` — 4 dependent(s) named
- `GS-CONTENT-002` — 3 dependent(s) named
- `GS-CONTENT-003` — 4 dependent(s) named
- `GS-CTRL-001` — 3 dependent(s) named
- `GS-CTRL-002` — 4 dependent(s) named
- `GS-GATE-001` — 3 dependent(s) named
- `GS-PACKAGE-002` — 1 dependent(s) named

## 4. What is NOT proven anywhere in this work

- **No hosted lane**: no run URL, ID, attempt or log was ever available; every result is a LOCAL
  reproduction of the constituent commands.
- **No device**: no emulator, simulator, physical phone, radio or clinical evaluation was used.
- **No independent verification**: not one finding is `VERIFIED_FIXED`.
- **Final convergence (T78) has NOT run**: there is no one clean exact candidate SHA carrying fresh
  green canonical + hosted controls, and the two candidate scopes (LIGHT Archive, Mesh/Oracle) are
  both still NO-GO.
- **Readiness is FALSE** and the five external gates are OPEN or BLOCKED: no ledger status or test
  pass in this work moved either.
