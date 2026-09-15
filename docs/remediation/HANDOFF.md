# Remediation handoff — AUDIT-003-R1

Ledger `REMEDIATION_STATE.json` (AUTHORITATIVE); protocol `README.md`; external requests
`EXTERNAL_INPUT_REQUESTS.md`; accounting `STATUS_ACCOUNTING.md`. Audit source `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` is READ-ONLY, and its own
process keepeth writing into the original checkout, whose declared addition GROWS (the floor may only rise).

## Status — 27 submitted (25 FIX_SUBMITTED, 2 PARTIAL), 27 OPEN

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
| GS-STORE-003 | FIX_SUBMITTED | 4a | Actual message-store upgrades still drop durable tables |
| CRYPTO-004 | FIX_SUBMITTED | 4b | The T35 low-order-DH negative tests exercise an unused hel |
| IOS-03 | FIX_SUBMITTED | 4d.1 | HS2 hint uses optional advertisement instead of GATT-bound |
| ANDROID-02 | FIX_SUBMITTED | 4d.2 | Canonical advertising makes the initiator's HS2 hint looku |
| GS-ACK-002 | FIX_SUBMITTED | 5 | Restart ACK worker uses TTL 4 while immediate recipient AC |
| CRYPTO-003 | FIX_SUBMITTED | 4b | Destroyed retained controllers and primitive sessions st |
| CRYPTO-006 | FIX_SUBMITTED | 4b | Duplicate journal admission is treated as success for a |

## DO THIS FIRST — the wave 4a chain: `GS-STORE-004`, then `GS-STORE-005`, then `GS-STORE-006`

`CRYPTO-006` is DONE on both isles (`92104a7` android + `36c0cc6` iOS): the journal claim is keyed by
the COMMAND REVISION, a duplicate carries the winning row, and a raced caller discards its own frame.
What it still owes (in its ledger entry, not in this lane): the DURABLE journal (step 3 — the seam
`CRYPTO-005` also needs), the relay/forwarding checks (step 5), and one unwitnessed defensive branch.

`GS-STORE-003`'s machinery is what 4a needs next — read what it left behind before editing:
`StoreSchema.frozenFingerprint` / `migrationPlan(from:creatingTables:supportedMax:)` on both isles, the
handle-bound executors (`HandleMigrationExecutor` / `DatabaseMigrationExecutor`), and the JVM host twin
`JdbcStoreDb`. To add a schema revision you add a real non-destructive step (e.g. `ALTER TABLE ... ADD
COLUMN`) and bump `dbVersion`/`DB_VERSION` TOGETHER on both isles, updating the frozen column lists in
the same commit. WATCH THE BLAST RADIUS: on Android the held-frame write goes through the `StoreDb`
interface, which has FOUR implementations, and `ReadinessT17Test.testReleaseSymbolsCarryNoTestFactories`
refuseth any new exported test seam on a production type — a mandatory lane, not a negotiable one.

## Then the wave 4a chain: `GS-STORE-004`, then `GS-STORE-005`, then `GS-STORE-006`

## The submissions THIS session made, and what each still owes

- **`GS-STORE-003`** (FIX_SUBMITTED, `98c69c5`): the audit's older-version fixture is SYNTHETIC (no real
  v4/v5/v6 DDL survives anywhere -- the destructive road was the only thing that ever touched those
  revisions), the Android production road is covered by source arms plus the JDBC host twin and nothing on
  a device, and no court injects a mid-step interruption through the store's own open road.
- **`CRYPTO-004`** (FIX_SUBMITTED, `5c03d06`): the opener's bounded reject is witnessed on the host; the
  multi-hop relay forwarding of a refused frame stays with T37/T84, and no radio path was exercised.
- **`IOS-03`** + **`ANDROID-02`** (FIX_SUBMITTED, `19a4635` + `098fcb2`): ONE law on both isles -- the hint
  for an already-bound relation comes from the GATT-bound relation, never from optional advertising
  metadata. The Android red is BEHAVIOURAL and reproduces the audit's schedule verbatim
  (`hs.read.initiator|no remembered discovery hint`); the iOS arm reads CODE because that isle has no
  transport harness. Still owed: the audit's adapter-driven closure case on the iOS isle, wave 4e
  reachability, and renaming `advertisedRemoteHint` (~15 call sites) which now carries the BOUND hint.
- **`GS-ACK-002`** (FIX_SUBMITTED, `bae4eba`): both restart ACK roads now pass the profile's named initial-TTL
  constant. Still owed: the DOWNSTREAM relay forwarding check (TTL decrement / hop increment once per
  outgoing copy, outgoing copy preserved on retries -- T84's evidence), and driving the IMMEDIATE road end
  to end in THIS court (its sender fixture has no Ed25519 keys; T37 drives it).

## A KNOWN FLAKE IN THE ANDROID LANE -- not fixed, and it weakens "the lane is green"

Across three forced full-lane runs (`./gradlew :mesh:testDebugUnitTest --rerun-tasks`) of the SAME tree,
two runs failed in FIXTURE SETUP in two DIFFERENT courts with the same message:

    "no ascending hint pair within 64 draws"   -- ReadinessT17Test.makeTrustedPair, then ReadinessT18Test

Each court PASSED when re-run and the third full run was fully green (1142 tests). The assertion is in
randomized identity drawing, before any product code runs, and 65 consecutive non-ascending draws from the
shared `SecureRandom` (`identityRng`) is statistically impossible -- so this looks like a FIXTURE
DETERMINISM BUG, not bad luck, and probably shared state in the in-memory identity storage. It is NOT fixed.
Do not report the Android lane as reliably green: report the logged passing run, and fix this fixture when
a round has room (a deterministic draw, or a failure message that names what it observed).

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

## Two things a round must not re-learn the hard way

1. **A mandatory lane is not negotiable.** `ReadinessT17Test.testReleaseSymbolsCarryNoTestFactories`
   refused a helper I added to `NoiseSession` for defense-in-depth (`installCiphersForTest` counts as an
   exported test factory on a production type). The repair moved the guard inline into the two EXISTING
   seams. Do not add an exemption to that court, and do not rename a seam to slip past it.
2. **A court that asks the REGISTRY cannot see a defect in the OBJECT.** Both isles' T08 courts already had
   `testDestroyedReferencesRemainTerminal`, and both were green on CRYPTO-003 -- because they asked the
   manager (whose `isReady` is false once the slot is removed) instead of the RETAINED controller/session.
   When a finding says "retained references still report X", the arm must hold the object and ask IT.

## A tooling trap that cost an edit this round

Inserting an arm with `text.rstrip().rfind("\n}")` as the anchor DELETED the file's trailing top-level
declaration: `ReadinessT36Test.kt` ends with `private data class Quad<A, B, C>(...)` AFTER the test class,
so everything past the class's brace was cut and W10's `Quad(...)` calls stopped resolving. Anchor an
insertion on something that is genuinely last, or re-read the file after editing it.
