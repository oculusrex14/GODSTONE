# Remediation handoff — AUDIT-003-R1

Ledger `REMEDIATION_STATE.json` (AUTHORITATIVE); protocol `README.md`; external requests
`EXTERNAL_INPUT_REQUESTS.md`; accounting `STATUS_ACCOUNTING.md`. Audit source `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` is READ-ONLY, and its own
process keepeth writing into the original checkout, whose declared addition GROWS (the floor may only rise).

## Status — 18 submitted, 36 OPEN

Not one finding is `VERIFIED_FIXED`: only an INDEPENDENT AUDIT may write that, and the ledger court
REFUSETH the word from this work.

| Finding | Status | Wave | Title |
|---|---|---|---|
| GS-CTRL-001 | FIX_SUBMITTED | 1 | Completion validator accepts failed commands, missing lo |
| GS-CTRL-002 | FIX_SUBMITTED | 1 | Readiness controls already fail on the audited task sequ |
| GS-GATE-001 | FIX_SUBMITTED | 1 | Release gate validation can bypass exact-SHA and executo |
| GS-ARCHIVE-001 | FIX_SUBMITTED | 2 | Archive runtime accepts usable bytes without the require |
| GS-ARCHIVE-002 | FIX_SUBMITTED | 2 | Android admits malformed archive schema and reports SQL  |
| GS-ARCHIVE-003 | FIX_SUBMITTED | 2 | Android search results cannot open the full document and |
| GS-ARCHIVE-004 | FIX_SUBMITTED | 2 | The iOS full-document reader has no scrolling container |
| GS-ARCHIVE-005 | PARTIAL | 2 | Archive navigation bypasses selection metadata and persi |
| GS-CONTENT-001 | FIX_SUBMITTED | 2 | Final chunk approvals are optional in release builds, an |
| GS-CONTENT-002 | FIX_SUBMITTED | 2 | Archive bytes and their receipts are published separatel |
| GS-CONTENT-003 | FIX_SUBMITTED | 2 | The default release validation/check-only path still acc |
| GS-MODEL-001 | FIX_SUBMITTED | 3b | Runtime model staging and loading can omit all provenanc |
| GS-PACKAGE-001 | FIX_SUBMITTED | 3a | The iOS artifact inspector accepts prohibited signed ent |
| GS-PACKAGE-002 | FIX_SUBMITTED | 3a | The Android artifact inspector validates AAB names but n |
| GS-SUPPLY-001 | FIX_SUBMITTED | 3a | Offline cache restore accepts traversal names and symlin |
| GS-STORE-001 | FIX_SUBMITTED | 4a | T29 proves a fake SQLCipher classifier, not the actual A |
| GS-STORE-002 | PARTIAL | 4a | iOS private stores still use ordinary SQLite without a s |
| GS-DIAG-001 | FIX_SUBMITTED | 8 | Diagnostics retain an unbounded map of historic relation |

## DO THIS FIRST — `GS-STORE-003`

Its RED is captured (three arms, all RED, parked in `tools/readiness/audit_probes/swift/` with their run
recipe) and the repair is FULLY SPECIFIED in the ledger. READ THE ORDER OF WORK THERE BEFORE EDITING: an
earlier attempt removed the four `DROP TABLE` statements first, and the experiment PROVED that wrong -- the
drops WERE the migration mechanism, so removing them without the engine leaveth a stale file on its old
schema. Sequence: (1) bind `SchemaMigrationEngine` through a `MigrationExecutor` over the sqlite handle;
(2) THEN remove the drops; (3) THEN reverse the court that currently REQUIRETH them
(`SqliteDeliveryRepositoryTests.testPragmaUserVersionMigrationDropsAndRecreatesOnStaleVersion`); (4) THEN add
the audit's row-survival probe (caveat: a synthetic older-version fixture, not a claim about every historic
schema).

## Other open PARTIALs, and what they owe

- **GS-ARCHIVE-005** (PARTIAL): STEP 1: choose ONE real document-selection owner on iOS and route destination selection through scene.open(document:) -- the app view still drives ArchiveDocumentReader directly
- **GS-STORE-002** (PARTIAL): THE CONCRETE ENGINE: `EncryptedStoreEngine` hath NO concrete SQLCipher implementation wired into this path -- the composition can now REFUSE, but the DEVICE must inject a real engine for the stores to

## The suite that measures this work

- `tools/readiness/tests/` — the GREEN lane.
- `tools/readiness/audit_probes/` — the audit's own 12-case suite: it began at SEVEN reds and is now FULLY
  GREEN (GS-SUPPLY-001, GS-DIAG-001, GS-PACKAGE-001, GS-PACKAGE-002 all repaired, each moving its arms
  verbatim into the canonical lane and inheriting the AUDIT'S OWN FIXTURE).
- Red-by-design probes (`kotlin/`, `swift/`) live OUTSIDE the build lanes with run recipes: a red arm inside
  a module reddens the lane, and the green lane must never be red.

## How to reproduce a RED

1. `git worktree add --force --detach <tmp> <PRE-REPAIR COMMIT>`; `cp android/local.properties <tmp>/android/local.properties`
   (a fresh worktree LACKS it and every Gradle command fails with "SDK location not found").
2. Copy ONLY the court in, and write its RED arms against PRE-EXISTING API only.
3. Swift: run `python3 scripts/sync_ios_foundation_package.py` AFTER every source edit, or `swift test`
   runneth the OLD copy and reports 0 tests.
4. A COMPILE FAILURE IS NOT A RED.

## Traps that have each cost a round

- A WITNESS GREEN ON BOTH REVISIONS PROVETH NOTHING (two were produced and reverted here).
- An arm may read the CODE while its charge liveth in a COMMENT -- and the reverse (W01 of GS-STORE-003
  FAILED on my own comment quoting `DROP TABLE`). Each arm must read where ITS limb liveth.
- An arm about WIRING that accepteth a SPELLING will pass on a comment (W02 of GS-STORE-003 did).
- A SKIPPED arm proveth nothing: make it FAIL on a rename instead.
- A control that PROTECTS THE BYPASS will be found (T52's deputy arms, T61's null-artifact arm, T29's stub,
  the SQLite stale-version court) -- reverse it and record the reversal IN THE ARM.
- A red that cannot be SATISFIED is not a red.
- Never leave a lane red: park the red probe outside it.
