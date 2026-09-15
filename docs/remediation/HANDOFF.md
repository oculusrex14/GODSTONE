# Remediation handoff — AUDIT-003-R1

Ledger `REMEDIATION_STATE.json` (AUTHORITATIVE); protocol `README.md`; external requests
`EXTERNAL_INPUT_REQUESTS.md`; accounting `STATUS_ACCOUNTING.md`. Audit source `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` is READ-ONLY, and its own
process keepeth writing into the original checkout, whose declared addition GROWS (the floor may only rise).

## Status — 29 submitted (27 FIX_SUBMITTED, 2 PARTIAL), 25 OPEN

Not one finding is `VERIFIED_FIXED`: only an INDEPENDENT AUDIT may write that, and the ledger court
REFUSETH the word from this work.

ROUND 85 landed `GS-SOS-002`'s ordered STEP 6 on the Android isle (commit `71003b7`, red captured in a
detached pre-repair worktree and failing on its OWN assertion with `hasActiveSos=true`): the Active-SOS
projection is now re-derived from the durable row through one `rememberSosCommit`, the law the iOS twin
already carried. The audit's step 3 stays OPEN, with its two measured obstacles written into item 1 below.

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

## DO THIS FIRST — the one thing each of the three richest entries still owes

The session that ran rounds 57–82 landed TWELVE repairs (ledger: 27 `FIX_SUBMITTED`, 2 `PARTIAL`, 25 `OPEN`,
zero `VERIFIED_FIXED`). What remains on the three most-specified findings is now ONE limb each — start here,
because the red design and the measured constraints are already written down:

1. **`GS-SOS-002` step 3 — serialize offer admission with cancellation.** The lease (both isles) and the
   DURABLE-TRUTH check (both isles) are landed, and both reds are captured and proven executed. ROUND 85
   landed the audit's ordered STEP 6 on the Android isle (the projection is now re-derived from the durable
   row via one `rememberSosCommit`, the law the iOS twin already carried — so no iOS source changed and the
   iOS package count stayed at 1193). What is NOT closed is step 3, and round 85 measured TWO obstacles that
   must not be re-discovered:
   - A per-message ADMISSION TRANSITION (one monitor taken by both the admission — lease + durable truth +
     the crossing mark — and the successful cancellation's invalidation) was IMPLEMENTED, measured and
     WITHDRAWN BEFORE COMMIT, because **no deterministic arm isolates the race window it closes**: every
     interleaving this court can express is already satisfied by the landed lease and durable-truth checks,
     so the red would have been a witness green on both revisions.
   - The audit's step 5 asks that in-flight bytes be reported as "possibly relayed", but
     `SosCancelResult.wasRelayed` CANNOT carry that: a PRE-EXISTING mandatory court
     (`ReadinessT39Test.testCancelVersusQueuedWriterNeverResurrects`) pins a mid-flight cancellation to
     `!wasRelayed` and FAILED when round 85 overloaded the flag. Do not weaken, exempt or rename that court.
     The honest shape is a NEW explicit in-flight observable on BOTH isles together.
   Carry the two older measured constraints too: the check must test the row's STATE (a terminal CAS KEEPS
   the row) and the FIRST offer is exempt (the DIRECT path commits its row after offering — gating it broke
   `MeshNodeDeliveryIntegrationTest.C6_6_1`).
2. **`GS-ACK-001` step 4 — LANDED ON BOTH ISLES at round 86 (`f77f6d9`), and it was a REAL hole.** Round 83's
   "satisfied by construction" was WRONG: the store gated on the pinned key and then asked for a verification
   that re-resolved it, so a resolver answering differently on the second call had a frame signed under its
   LATER answer filed as `VERIFIED_RECIPIENT`. The red proved it with an attacker-supplied frame on the
   ADMISSION road (`Stored(ackKey=...)`). Fixed with a defaulted `verifyWithCapturedKey` on both isles.
   TWO THINGS TO CARRY FORWARD FROM IT: (a) the first arm (restart road, signer seam) came back GREEN on the
   pre-repair tree and proved nothing — a forged frame must arrive where the bytes are attacker-supplied;
   (b) the first refactor inverted a PINNED pre-resolver-guard law (zero key lookups for a structurally
   invalid frame, `BoundRecipientKeyResolverTest`), which only the WHOLE lane caught — run the lane, not the
   court you happened to touch. Still owed: the tracker road's absence of this hole is an INSPECTION, not an
   arm, and the iOS limb carries no arm of its own.
3. **`GS-STORE-004`** (the wave 4a chain's next link) — the retention checkpoint: a REAL non-destructive
   migration step plus the persisted checkpoint and the reopen debit. `GS-STORE-003` left the machinery
   (`frozenFingerprint`, `migrationPlan`, the handle-bound executors, the `JdbcStoreDb` twin); adding a schema
   revision means a real `ALTER TABLE ... ADD COLUMN` step and a `dbVersion`/`DB_VERSION` bump TOGETHER on both
   isles, watching the four-implementation `StoreDb` interface and the mandatory
   `testReleaseSymbolsCarryNoTestFactories` lane.

ALSO WORTH A ROUND, and cheap: the android lane's unexplained FIXTURE flake ('no ascending hint pair within 64
draws', seen in ReadinessT17/T18 fixture setup and green on re-run) — fix it deterministically so 'the lane is
green' stops meaning 'the logged run was green'.

## READ THIS BEFORE CHOOSING A FINDING: ELEVEN OPEN ENTRIES ARE UNENRICHED

Verified at round 93 by inspecting the ledger, not by inference: of the 25 `OPEN` findings, these ELEVEN
carry the audit's title and severity and NOTHING ELSE -- no `impact`, no `remediation_steps`, no
`source_refs`:

    ANDROID-01, ANDROID-03, ANDROID-04, ANDROID-05, ANDROID-07,
    IOS-01, IOS-02, IOS-04, IOS-05, IOS-06, IOS-07

`ANDROID-06` was in exactly that state until round 92, when its card was read verbatim
(`AUDIT_FINAL_2026-09-15/evidence/android/findings.md`, the per-finding sections) and its fields filled --
and the card immediately yielded the cheapest red AND its positive control, which no amount of staring at
the title would have produced. That is the pattern to repeat: for any of the eleven, read the card in
`evidence/android/findings.md` (Android) or the iOS findings file FIRST, fill `impact`,
`remediation_steps`, `source_refs` and `closure_tests` from it, name the cheapest red, and only then design
the arm. A round that starts on an unenriched entry spends itself on reconnaissance.

## Then the wave 4a chain: `GS-STORE-004`, then `GS-STORE-005`, then `GS-STORE-006`

## AND THEN, with its red already designed: `GS-SYNC-002` step 3 (retired control replies) — ANDROID LANDED

Round 86 landed the ANDROID limb: `ControlReply` is stamped with a per-peer RELATION EPOCH, the epoch is
retired on `PeerEvent.Lost`, and both drains drop an entry whose epoch is no longer current. Still OWED: the
**iOS twin** (same law, no epoch there yet). THREE OBSERVABLES WERE TRIED for this arm and two were withdrawn —
read `GS-SYNC-002/red/gs-sync-002-withdrawn-observables.txt` before writing a similar arm: asserting the whole
DRAIN is empty measures the PUMP (the new relation's own frames ride it, so the count went 2 → 1, not 2 → 0),
and filtering by the ping's msg id matches nothing because the answer carries its OWN id — that arm **passed on
the pre-repair revision** and proved nothing. The observable that isolates the named thing is the
**no-argument `drainControlOutbox()`**, which carries only outbox entries.

Both isles carry `ControlReply(destination:frame:)` and a per-destination drain, but NOT a RELATION
GENERATION, so an answer queued for a relation that was RETIRED can ride the REPLACEMENT relation when the
same peer reconnects. RED, deterministic and host-executable in the two sync courts: enqueue one control reply
for peer P, drive P's disconnect (retiring that relation), reconnect P as a NEW relation, then drain for P --
expect ZERO frames and an outbox empty for P. Today the stale answer is handed over, so the arm reds on its
own assertion. Fix shape: carry the generation in `ControlReply`, drop a destination's entries on relation
retirement, and revalidate the captured generation at writer admission -- the same "revalidate what you
captured before committing it" law the sync owner's step 4 asks for. Careful with step 4 itself: a
per-destination cap is a FAIRNESS bound, not a memory one (the aggregate 64 already bounds memory, and
drop-oldest means a flood cannot starve a later reply of admission), so an arm claiming starvation would be a
witness green on both revisions.

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

## THE ANDROID LANE FLAKE — ROOT-CAUSED AND FIXED (round 86), so "the lane is green" is a real claim again

The former note said the failure was "statistically impossible" and blamed shared RNG state. That reading was
WRONG, and the correction matters: the fixture redrew **`b` alone** until its hint sorted after a **fixed
`a`**, so the acceptance probability per draw was `(255 - a.hint[0])/256` — **not one half**. When `a.hint[0]`
landed at 254, each draw needed the 1/256 case `b.hint[0] == 255`, so sixty-five draws failed with
probability ~78%. MEASURED, not guessed, by instrumenting the two loops in a detached worktree and running the
filtered courts repeatedly:

    FLAKE-PROBE FAILED draws=65 a=254,25,59,239 b=67,174,80,195 identical=false aIdEqBId=false
    FAILED testAttestTwentyTwentyCarriesTheFullDigest :: no ascending hint pair within 64 draws

NINE of THIRTY filtered runs failed, all of them in FIXTURE SETUP, all in the two courts that carry the
`b`-alone shape (`ReadinessT17Test`, `ReadinessT18Test`) — and the other five courts (`T20`, `T21`, `T22` ×2,
`T23`) carry the both-redrawn shape, whose acceptance probability is ~1/2 per draw and whose 65-draw failure
is genuinely impossible, so they never flaked. The repair ORDERS the drawn pair (and fails with a message
naming the two hints if they are equal, which needs a 2^-32 collision) instead of fishing on the coin, and it
is verified by the SAME thirty-iteration protocol that produced the nine failures.

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
4. A COMPILE FAILURE IS NOT A RED — and neither is a HARNESS MISUSE. Round 85 lost a capture to a nested
   `runTest { }` inside a `= runTest { }` body: the arm failed with
   `IllegalStateException: Only a single call to runTest can be performed during one test`, which proves
   NOTHING about the product. Call the suspend function directly inside the body. A red must fail on the
   ARM'S OWN ASSERTION, and the arm must be NAMED in the court's XML/runner output.
5. CAPTURE THE RED IN A PRE-REPAIR WORKTREE, not only in the working tree: `git worktree add --force --detach
   /tmp/<name> <PRE-REPAIR SHA>`, copy the court in, copy `android/local.properties`, run, and record the
   worktree path, the SHA and the fact that production was untouched. Round 85's valid red was captured this
   way and its log names the worktree.

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
