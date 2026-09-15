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

## ROUND 111 — A CORRECTION I OWE, AND THE NEXT TARGET'S REAL BLOCKER

ROUNDS 109–110 LABELLED THEIR LIMB "T09". THE LIFECYCLE AUTHORITY's frozen-availability defect is real
and IS repaired (`UnifiedRuntimeLifecycle` now asketh the platform at each start; a revocation EVENT
stayeth terminal; the pinned T28 law is green). BUT THE SUPPLEMENT'S **ANDROID-05-A NAMETH A DIFFERENT
SCHEDULE, AND IT IS STILL OPEN**:

    BleTransport.kt:200-209
        override fun start() {
            if (isStarted) return
            isStarted = true                  // <-- set BEFORE the OS start SUCCEEDETH
            val serverStarted = gattServer.start()
            if (!serverStarted) return       // <-- a FALSE return leaveth isStarted TRUE
            startAdvertising()
        }
    "isRunning can be false while retry is suppressed." -- and the supplement WARNS that
    `isRunning == false` ALONE MISSETH the defect: the arm must observe whether the SECOND call
    ATTEMPTETH GATT startup at all (count the attempts).

MANDATORY CLOSURE (the supplement's own words): first GATT start fails -> the transport is completely
non-started, with no advertising or stale owned server/lease/session state -> second start retries GATT
and succeeds -> valid service readiness begins advertising EXACTLY ONCE. Deliver a delayed
first-attempt callback before and after the retry; it has ZERO effect. Duplicate start/stop and stop
during starting remain idempotent. Include partial allocation followed by failure AND a failure before
allocation.

THE BLOCKER IS STEP 1, AND IT IS A REFACTOR: "Add an injectable OS GATT boundary to the actual
`BleTransport` construction path." `BleGattServer` is a FINAL class with a heavy constructor (context,
uuids, provider lambdas), so the boundary meaneth extracting an INTERFACE over its public surface
(start / stop / isRunning / isServiceReady / cancelConnection / isSubscribed / sendNotification / ...).
That is a whole round, and it is why round 111 did NOT start it: a half-extracted interface would have
left the :mesh lane red, which this work may never do.

## ROUND 105 — THE ANDROID LANE IS VERIFIED HERE, AND THE NEXT REPAIR IS NAMED

Every OPEN HIGH finding left is a **Kotlin or Swift** repair, so this round measured the toolchain
instead of guessing at it:

    cd android && ./gradlew :mesh:testDebugUnitTest --tests '*ReadinessT20Test*' --tests '*ReadinessT23Test*'
    -> BUILD SUCCESSFUL, both courts pass, real 0m1.916s WITH THE GRADLE CACHE WARM (30 of 31 tasks
       up-to-date). A COLD run will be far slower; do not quote 2s as the lane's cost from scratch.
    JDK: Temurin 17.0.20.1. SDK: ~/Library/Android/sdk. `android/local.properties` IS PRESENT in
    this worktree (a fresh `git worktree add` LACKS it and every Gradle command fails with
    "SDK location not found" -- the known trap).

NEXT TARGET, CHOSEN FOR THE CHEAPEST HONEST RED: **`ANDROID-04`** (wave 4f.2, HIGH) -- "Deadlines
have no scheduled owner and use wall-clock time". Its card (now transcribed into the ledger) nameth
two independent defects, and the SECOND is the cheapest to red on: `BleConnection.kt:31` defaults its
clock to `System.currentTimeMillis()/1000L` while the handshake/confirmation/assembly deadlines
consume it, and the card recordeth that **"a wall-clock rollback can extend the deadline further"**.
A red can therefore be built WITHOUT a scheduler at all: drive an already-armed deadline, ROLL WALL
TIME BACKWARD, and assert the deadline is not extended (monotonic behaviour). The FIRST defect
(`BleTransport.kt:877` defers `sweepInboundLeases` with no production caller) needeth the full
scheduler closure and belongeth to the same finding's later limb. Its card's own closure tests are in
the ledger (`REMEDIATION_STATE.json`, `ANDROID-04.closure_tests`) -- read them before designing.

## ROUND 103 LANDED — THE BARRIER SCHEDULE, AND ONE REAL DEFECT AMONG FOUR ARMS (`c7754e7`)

Four arms now kill a REAL process at each transition and restart the ACTUAL reader. Exactly ONE was
a defect: **W15 (orphan cleanup)** was RED and is repaired -- a RESOLVED publication rmtree's its
rollback directory. **W12 (prepared), W13 (committed) and W14 (failed rollback)** are COVERAGE of
already-satisfied behaviour and were GREEN in the same pre-repair run; they are labelled as such and
are NOT counted as repairs. The red was RE-CAPTURED in a detached worktree because the repair had
already been applied when it was first observed -- a red is evidence, not a transcript line.

STILL NOT EXERCISED from that same card (step 5): **READER OVERLAP** -- no arm runs a reader
CONCURRENTLY with the publisher -- and the card's "two real processes with controlled barriers",
whereas these arms kill one process per transition and restart the reader afterwards.

## DO THIS FIRST (round 102) — THE OPERATOR PAIR'S SECOND PAIR-OF-RENAMES, WITH ITS RED ALREADY CAPTURED

`scripts/prepare_release_assets.py::publish_verified` replaceth its ARCHIVE and its APPROVED MANIFEST
with **TWO INDEPENDENT `os.replace` calls** (lines 536 and 548), with **no journal, no commit states
and no recovery consumer**, while `build_archive.publish_archive_pair` has all three. A crash between
them leaves an approved manifest describing bytes that are not there, **permanently**: the shared
consumer (`build_archive.recover_publication`) cannot help, because no journal existeth for that pair.

THE RED IS CAPTURED AND PARKED OUTSIDE THE LANES (a red arm may not sit in a lane expected green):

    python3 tools/readiness/audit_probes/python/audit004_operator_pair_probe.py
    -> 1 test, 1 FAILURE, on its OWN assertion ("the approved manifest describeth bytes that are
       not there, and no journal existeth for the staging pair")
    log: REMEDIATION/GS-CONTENT-002/red/audit004-second-pair-RED-*.log (sha256 17d7ce33...)

THE ROUTE, AND THE TRAP MEASURED THE HARD WAY (round 102, code WITHDRAWN BEFORE COMMIT): routing the
staging pair through the shared journal was implemented -- `write_publication_journal(companion=...)`,
`clear_publication_state`, a companion-aware `recover_publication`, and `_restore_pair` in the staging
face -- and it WORKED for its own arm. It was withdrawn because **the journal and the rollback
directory land INSIDE the operator output directory**, which `stage()` enumerateth exactly and which
the T77 rehearsal court asserteth at EVERY publication boundary: measured cost **5 failures + 6 errors
in the readiness lane and 1 error in the content lane**. So the NEXT round must move the journal's
LOCATION (or teach those courts what a publication-internal artifact is) TOGETHER WITH the change --
not discover the collision again. Start with the T77 estate courts and
`ReleaseAssetTests.test_source_mutation_during_copy_preserves_existing_output`.

## DO THIS FIRST (round 97) — THE AUDITOR'S OWN PROBE SUITE IS THE PRIORITY, AND IT IS EXECUTABLE

`AUDIT_FINAL_2026-09-15/evidence/AUDIT-004/independent_repair_probes_v2.py` is the INDEPENDENT
review's own 10-case suite, and it is the highest-signal measure of this work: it is the only
executable artifact that says which auditor-reproduced defects are STILL THERE. Run it in a
detached worktree (never in the live tree) with `AUDIT_SOURCE_ROOT` naming that worktree and
`/Users/oculus/Projects/GODSTONE_AUDIT/evidence/AUDIT-002/content/venv/bin/python`. It needs its
`schema_version` fixture, which v2 carrieth; there is NO `-v` flag, and passing one errors.

    ROUND 100 MEASURED IT AT 1a31f47: **10 PASS, 0 FAIL — THE ENTIRE SUITE IS GREEN.** The audit's
    own pin was 8 failures / 2 passes, and ae9905e was also 8/2. ALL EIGHT reproduced failures are
    repaired, one finding-limb per round:
      | probe | finding | state |
      |---|---|---|
      | the three `EvidenceTests` | GS-CTRL-001 | PASS (round 97) |
      | `test_null_device_proof_is_rejected` | GS-GATE-001 | PASS (round 98) |
      | `test_expression_disabled_ci_job_is_rejected` | GS-GATE-001 | PASS (round 98) |
      | `test_operator_heldout_validation_reaches_valid_verifier` | GS-CONTENT-003 | PASS (round 98) |
      | `test_forged_approval_digest_and_zero_coverage_cannot_stage` | GS-CONTENT-001 | PASS (round 99) |
      | `test_process_death_cannot_expose_mixed_archive_and_receipt` | GS-CONTENT-002 | PASS (round 100) |
    ROUND 101 (`ee68ee0`) LANDED THE DURABILITY LIMB of GS-CONTENT-002's step 5, and it was a real
    hole: `_fsync_directory` SWALLOWED its failures, the retained backups and the journal were
    NEVER fsynced, and a refused terminal journal record escaped as a bare OSError while the
    generation WAS published. Durability failures now PROPAGATE, `_write_journal` is durable
    (bytes fsynced before the rename, the directory entry before the caller proceedeth), each
    retained backup is fsynced BEFORE the destructive promotion, and a failed terminal record
    raises the product's OWN error naming the true state. Three arms (W09-W11) hold it; the
    refusal is aimed at a DIRECTORY fsync only, so no arm can pass on an unrelated failure.

    **A GREEN PROBE SUITE IS NOT A CLOSED FINDING** — it is a suite written BEFORE the repairs, and
    only an independent audit may write `VERIFIED_FIXED`. THE DEPTH STILL OWED ON GS-CONTENT-002:
    two REAL processes with controlled barriers killed at EACH transition (prepared / promoted /
    committed), reader overlap, a FAILED rollback, orphan cleanup (the durability boundaries are
    now proven by INJECTION, not by process death at every barrier); ONE publication owner shared
    by build and operator staging (`scripts/prepare_release_assets.py` STILL replaces archive and
    approved manifest INDEPENDENTLY -- a second pair-of-renames with no journal and no recovery
    consumer); and the stronger generation-pointer design the card preferreth. (The fsync order
    itself is now repaired -- see round 101 above.)

## THE FORMER "ONE THAT REMAINS" — KEPT FOR THE RECORD, NOW REPAIRED

    The text that stood here said:
      * `GS-CONTENT-002` — a real `os._exit(87)` between DB and receipt replacement leaveth a MIXED
        pair (an accepted receipt hash describing the OLD database beside the NEW one). The repair
        requireth journal RECOVERY: a durable staged pair and a durable previous pair, explicit
        commit states, startup recovery BEFORE any reader or new writer proceeds, one canonical
        interprocess owner, fsync in the correct order (the backups and journal are not fully
        fsynced before destructive promotion, and `_fsync_directory` swalloweth failures), a
        `read_sidecar` that may not accept a stale receipt, and ONE publication owner shared by
        build and operator staging (`scripts/prepare_release_assets.py:445` still replaces the
        archive and the approved manifest INDEPENDENTLY). The audit's process-exit case must stay
        a REAL process exit: do not replace it with a catchable exception, and do not move the
        fault after both replacements.
      * AND THE OWED BOUNDARY ON GS-CONTENT-001: binding the VERIFIED covered-chunk cardinality and
        the approval receipts to the transformed corpus, trust policy and validation date. It
        requireth the approvals bundles and the reviewer keyset at the CLI -- and note WHY the
        cardinality-equality law cannot substitute: the auditor's own valid fixture carries
        `approvals_covered='1'` over a thirty-chunk archive.
    Run the suite exactly as round 97 recorded: detached worktree, `AUDIT_SOURCE_ROOT` naming it,
    the audit venv, NO `-v` flag.

## ROUND 98 ALSO, AND IT IS THE BIGGEST SINGLE CONVERGENCE LEVER

`GS-CONTENT-003`'s obsolete refusal was removed from `scripts/prepare_release_assets.py::validate`
(it ran AFTER the trust-store law, so every valid operator-selected held-out evaluation was refused
before its verifier ran — a regression the auditor proved against the prior baseline). **A
canonical arm that PINNED that regression was reversed** (`test_the_deputy_face_refuseth_to_carry_an_
evaluation`) with its trust assertion retained and the reversal written INTO the arm.

THE CANONICAL CONTENT SUITE IS STILL RED, AND ITS ROOT CAUSE IS NOW NAMED: **71 cases, 13 assertion
failures, 10 errors** (was 69/14/10 before the repair — nothing was made worse). AUDIT-004 called
this a CONVERGENCE failure, not 23 new product defects: the class fixture in
`content/tests/test_heldout_staging.py` and `content/tests/test_prepare_release_assets.py` omits the
provenance metadata GS-CONTENT-001 made mandatory (`approvals_sha256` / `approvals_covered` in the
archive's own meta, which the signed manifest must then swear), so old POSITIVE cases fail too early.
THE FIXTURES MUST BE REPAIRED TO EXERCISE THE NEW CONTRACT — a synthetic digest installed exactly as
the independent probe did, claiming no human approval — and production validation must NOT be
relaxed to make them green. That is the single highest-value next round.

## ROUND 97 ALSO LANDED — `GS-CTRL-002`, the AUDIT-004 limb (`7c04539`)

The review found the content lane declared the rehearsal's external report path and NEVER uploaded
it, so the whole rehearsal left no retrievable artifact (the report liveth outside the source tree
BY LAW). The canonical court (`test_t77.py` W-R6) DERIVES the expected upload path from the lane's
own `T77_RUN_DIR` env and the rehearsal step's own `--report` argument -- never a hardcoded spelling
-- and requires `if: always()`, so a LATER red stage cannot destroy the report. The workflow gains
one pinned upload step. Rerun verbatim at this SHA: selftest rc 0, rehearsal 12/12 agreed, court
rc 0, `git status` unchanged, gate checker rc 0 with every mandatory lane still mandatory.

AND ONE LEDGER DEFECT, FOUND AND FIXED BY MEASUREMENT: a full recheck of **157** log and red-case
references resolved on disk (round 96 had left one instance) found GS-CONTENT-003's mutation roster
stored under the key `path` with a NULL digest. The key was corrected and the digest COMPUTED from
the file -- a measurement, not a fabrication. The recheck now finds **0 defects**.

## ROUND 97 LANDED — `GS-CTRL-001`, the AUDIT-004 limb (`bf839fa`)

The independent review of this finding's FIRST submission reproduced THREE bypasses that the
adopted arms did NOT catch, because each of those arms changed SEVERAL fields at once and so
passed for a defect other than the one it nameth. Its three probes are now adopted
assertion-intact (class `AdoptedAudit004EvidenceTest`, each negative changing EXACTLY ONE field
of an otherwise-valid record, with W09 the retained positive control), and the repair:

  * made the roster law REACHABLE — it was entered only when `tests_executed` was ALREADY truthy,
    so its own zero-executed check could never fire, and `tests_failed` was never validated;
  * removed the MUTATION EARLY-RETURN — a nonempty `note` used to suffice beside exit 99, zero
    executed and a nonexistent log. A lineage record is now validated AS ONE (source identity,
    real log + sha256, a failure roster NAMED and FOUND in that log, and a restored-green
    companion in the same manifest).

WHAT THE STRICTER LAW EXPOSED: T05's mutation record carrieth NO log, NO roster field, NO source
identity and NO restored-green companion, so it can never validate as a lineage record. It is NOT
exempted and its claim is NOT reasserted — the `mutation_records` entry was REMOVED and the id
reclassified into `evidence_absent_do_not_rely` as a gap, with the mutation control stated as NOT
ESTABLISHED. Nothing was deleted; `validate-state` stayeth GREEN (rc 0, 8 notes, one of them new
and named). STILL OWED on this finding: AUDIT-004 step 4 (source/tree BINDING) and the hosted lane.



## THEN — the one thing each of the three richest entries still owes

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

## READ THIS BEFORE CHOOSING A FINDING: THE ELEVEN ARE NOW ENRICHED (round 104)

The eleven OPEN entries that carried ONLY a title and a severity -- `ANDROID-01`, `ANDROID-03`,
`ANDROID-04`, `ANDROID-05`, `ANDROID-07`, `IOS-01`, `IOS-02`, `IOS-04`, `IOS-05`, `IOS-06`,
`IOS-07` -- now carry `impact`, `remediation_steps`, `source_refs` and `closure_tests`, TRANSCRIBED
FROM THE AUDIT'S OWN CARD (`evidence/android/findings.md#, evidence/ios/findings.md#`), not
summarised and not invented. A round can therefore start designing an arm IMMEDIATELY instead of
spending itself on reconnaissance. The `source_refs` are the card's own explicit `file:line`
citations and are RELATIVE TO THE AUDITED SNAPSHOT; where a card also cites bare line ranges inside
the one file it nameth, those ranges are still only in the card -- read it.

WHAT THAT UNLOCKED, AS AN EXAMPLE OF THE PATTERN: `ANDROID-06` was in exactly this state until
round 92, when its card was read verbatim -- and the card immediately yielded the cheapest red AND
its positive control, which no amount of staring at the title would have produced. Read the CARD
first for any of the eleven, name the cheapest red from its `closure_tests`, and only then design
the arm.

## (HISTORICAL) READ THIS BEFORE CHOOSING A FINDING: ELEVEN OPEN ENTRIES WERE UNENRICHED

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

## AND THEN, with its red already designed: `GS-SYNC-002` step 3 (retired control replies) — LANDED ON BOTH ISLES

> CORRECTION (round 97): the paragraphs below were written when only the ANDROID limb had landed; the
> **iOS twin landed at `bd98b26`**, its own arm at `fb75e78`, and the audit's step 4 (a per-destination
> bound beside the aggregate cap) at `4b7ff26`/`c67ca79`. The LEDGER is authoritative where this prose
> and it disagree.

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
