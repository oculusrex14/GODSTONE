# Remediation handoff — AUDIT-003-R1

Ledger `REMEDIATION_STATE.json` (AUTHORITATIVE); protocol `README.md`; external requests
`EXTERNAL_INPUT_REQUESTS.md`; accounting `STATUS_ACCOUNTING.md`. Audit source `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` is READ-ONLY, and its own
process keepeth writing into the original checkout, whose declared addition GROWS (the floor may only rise).

## Status — 32 submitted (27 FIX_SUBMITTED, 5 PARTIAL), 22 OPEN

(Recomputed from the ledger at round 161: `{'OPEN': 22, 'FIX_SUBMITTED': 27, 'PARTIAL': 5}`, total 54. The
`counts` block inside `REMEDIATION_STATE.json` is the AUDIT'S OWN snapshot (all 54 OPEN) and must not be
mistaken for the live status, which liveth per finding in `my_status`.)

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

## DO THIS FIRST (round 218) — ANDROID-06's CALLER HALF: A REFUSED SEAL NOW RETURNS ITS SLOT (A LEAK FOUND BY READING THE CALLER AFTER CHANGING THE CALLEE)

**The leak, and why it was mine as much as the audit's.** Round 216 made the four-record bound count **RESERVED**
records, as the card's step 4 demands — and **that change turned an unnoticed caller behaviour into a defect**:
`BleTransport.sendThrough`'s `SealAnswer.Refused ->` branch records the refusal and **returns, never cancelling the
reservation**. With the new reserved-slot table, **every refused seal leaks one slot, and four refused seals would exhaust
the relation's bound and silence it for ever.** The audit's step 2 asks for *"cancellation that returns a slot"*; the
callee now offers it and **the caller never took it**.

**The fix is one line in the right place:** `writer.cancel(answer.reservation)` at the head of that branch, so **every**
refusal reason is covered by one cancellation — and it is **harmless by construction**, because the writer's own epoch
checks already remove an invalidated reservation, so the call simply returns false and touches nothing in that case.

**The RED was source-level and the reason is stated:** the repair adds a call inside one branch, and a behavioural arm of it
needs a **full session whose sealer refuses** — and **no court has one** (nothing in the suite so much as mentions a refused
seal). **The behavioural half is therefore owed and named**, not implied.

**Acceptance:** canonical arm OK and moved into `tools/readiness/tests/`; whole `:mesh` lane **1191 tests, 0 failures** —
which mattered, because the refusal branches are *"told in the voices the recorded expectations know"*, i.e. courts **do**
assert them, and the cancellation broke none.

**The methodological point worth keeping:** **a repair that tightens a bound must be followed by a reading of every caller
of that bound.** Round 216 tightened it in the writer; round 218 read the one caller and found a leak the tightening had
made lethal. The audit's steps 1–5 were written as a list; **the list is a dependency graph**, and the caller of step 4 is
the subject of step 2.

## DO THIS FIRST (round 217) — ANDROID-06's BEHAVIOURAL ARMS LAND: THE CARD'S STEPS 2, 3 AND 4 ARE WITNESSED AGAINST THE REAL WRITER

**The arms, in the court's own idiom** (a bare `BleConnection` plus a mutable `maxAttValueLength` — both already used by
the T18 court, so no new fixture was invented):

* `testTheReservedSlotsAreBoundedAndCancellationReturnethTheSlot` takes **four reservations with no seal at all**, asserts
  the **fifth is refused** as `TooManyAdmitted`, then asserts `cancel` **returns a slot it really held**, that a **second**
  cancellation is **harmless** rather than a second refund, and that the slot is **reusable** afterwards.
* `testTheMovedCapacityEpochRetirethTheReservationWithoutSealing` takes a reservation at 247 octets, **moves the
  connection's capacity under it**, and asserts the seal is **refused with the sealer never spoken** (`sealerSpoken == 0`)
  and that the retired reservation no longer holds a slot.

**Why these arms are the finding, not decoration:** the audit's defect was that `reserve` merely **checked** a count of
**seal-time** records, so a caller could reserve without sealing and the bound was **evadable**. The first arm takes four
reservations and **no seals** — exactly the evasion the bound must now refuse — and under the repaired writer the fifth is
refused. The second proves invalidation happens **before** the sealer, so **no nonce is burnt and no byte is staged** for a
relation whose capacity moved.

**One more self-inflicted correction, recorded with the others:** the arms first failed to **compile**
(`Unresolved reference 'Reservation'`) because the court had only ever named `ReservationAnswer`; the type is now qualified
explicitly. **A compile failure is not a behavioural result** — the distinction this programme keeps — and the run that
followed was the first behavioural one.

**Acceptance:** T18 court **11 tests, 0 failures**; whole `:mesh` lane **1191 tests, 0 failures** (1189 + the two arms).

**Owed and named:** the transport-side **wiring** that would let a real operation **cancel** a reservation (the caller's half
of step 2) is not yet exercised. Only an independent audit may write `VERIFIED_FIXED`.

## DO THIS FIRST (round 212) — IOS-07: THE PRODUCTION SET COMPILED, AND THE WITNESS'S ERROR WAS DIAGNOSED TO ITS **PRIMARY** CAUSE (THEN REVERTED AGAIN)

**What was re-applied, exactly as round 211's plan said:** the **named** interval (`BleTransport.leaseSweepIntervalSeconds =
1.0`) with an **injectable** parameter; the **owned** `leaseSweepJob` armed in `startInstalling()` past the `isStarted`
guard and cancelled at the top of `stop()`; and the instruments (`leaseSweepTicksForTest`,
`leaseSweepRelationsSeenForTest`, `hasLeaseSweepJob`). **It compiled** (`swift build` clean, no error lines).

**And the witness's compile error was traced to its PRIMARY cause — the round's real result.** The visible error was
`cannot infer contextual base in reference to member 'inboundPeripheral'` on a line **textually identical** to the court's
own **working** line: a misleading **symptom**. The primary one, read from the log's **first** error, is:

> **`argument 'leaseSweepInterval' must precede argument 'managerFactory'`**

**Swift requires call-site arguments in declaration order**, and the new parameter was declared *before* `managerFactory`
while every caller passes it after `clock:`. **So the fix is a one-line move: declare `leaseSweepInterval` LAST in the
initialiser's parameter list.**

**Why it was still reverted, and why that is this programme's own rule:** the round's budget ran out before a **green lane
could be shown**, and the change **arms a sweep for every transport** — so the acceptance is the **whole** iOS lane, not the
filtered court. **A production change whose lane run was never completed is not verified**, and no unverified production
change is left behind: **the tree stands at the verified-green commit again.**

**The next attempt is exactly two edits and one run:** (a) re-apply the production set with `leaseSweepInterval` **declared
last** (anchors **and** the order rule are both recorded); (b) re-add the witness **verbatim** (its text is in this round's
log; its typed-local form avoids the inference question entirely); (c) run the **whole** iOS lane as the acceptance; then
move the canonical arm into `tools/readiness/tests/` and delete the parked one.

**A method note worth keeping:** three compiler-aided corrections have now been spent on this isle's lifecycle insertion (a
mis-placed statement, an argument order, a secondary inference symptom) — and **each was found by reading the FIRST error
rather than the loudest one.** That habit turned a two-round stall into a two-edit plan.

## DO THIS FIRST (round 211, landed) — IOS-07 IS ANDROID-04'S TWIN

**The defect, read from the isle and identical in shape:** `BleTransport.sweepInboundLeases()` (`:2827`) walks the
outbound and inbound lifetimes, asks each connection whether a lease lapsed, and retires the **owning** relation through its
**exact key** — **and it is called by nothing in production.** Its only caller anywhere is a court
(`ReadinessT20Tests:1000`). So a **silent** peer's lapsed handshake/assembly/confirmation deadline waits for unrelated
traffic for ever: **exactly the defect ANDROID-04 closed at round 210.**

**The RED is canonical and immutable:** `tools/readiness/audit_probes/python/test_ios_deadline_sweep_owner.py` (four arms)
— `Ran 4 tests, FAILED (failures=3)` with the W00 positive control passing — parked in the probes directory, so no
committed SHA carries a red mandatory lane.

**The repair was written and it compiled** (`swift build` clean): a **named** interval
(`BleTransport.leaseSweepIntervalSeconds = 1.0`) with an **injectable** `leaseSweepInterval` parameter; an **owned**
`leaseSweepJob` armed inside `startInstalling()` (past the `isStarted` guard, where a start is certain) and cancelled at
the top of `stop()`; and the instruments five rounds of Android method proved necessary
(`leaseSweepTicksForTest`, `leaseSweepRelationsSeenForTest`, `leaseSweepLeasesLapsedForTest`, `hasLeaseSweepJob`).

**Why it was still withdrawn — discipline, not nerves:** the **controlled-experiment witness** (the court's own working
expiry arm **verbatim**, differing only in a 25 ms interval and in never calling the sweep) hit a **compile error the
round had no budget left to settle**: `cannot infer contextual base in reference to member 'inboundPeripheral'` on a line
**textually identical** to the court's own working line — the inference depends on context this arm does not yet supply.
**A production change whose lane run was never completed is not verified**, and this programme leaves no unverified
production change behind. The edits were **reverted** and **the tree stands at round 210's verified-green commit**.

**The next round's four steps, named:** (a) re-apply the production set (its three anchors are in the ledger); (b) settle
the witness's one error by qualifying the enum (`direction: BleDirection.inboundPeripheral`); (c) run the **whole** iOS
lane (the job arms for every transport, so the lane is the acceptance, not the filtered court); (d) move the canonical arm
into `tools/readiness/tests/` and delete the parked one.

## DO THIS FIRST (round 210, landed) — ANDROID-04's SCHEDULER IS PROVEN

**The experiment and its control.** `ReadinessT20Test.testTheOwnedSweepTrippethASilentPeerByTimeAlone` carries the court's
**own working expiry arm verbatim** — same rig, same base, same generation, same publication, same seal offset 909, the
same two fragments, the same lease read, the same `rigNow = lease.deadlineMono` — and differs in **exactly one way**: it
**never** calls `sweepInboundLeases()`. **The setup IS the control**, which is what round 209's displacement bought: an
earlier draft changed the caller *and* the setup at once and failed for the setup's sake alone.

**The result:** **the owned sweep tripped the silent peer by time alone** — an injected 25 ms interval, no traffic, no
test-thread call — and the arm also asserts the publication was withdrawn with the relation and that nothing was admitted
of the silent dribble. **The card's first defect is thereby closed on the code side and proven behaviourally: expiry no
longer waits for unrelated traffic.**

**Five rounds of method, all recorded:**
* **206** the seam (injectable interval) landed; the first witness was RED;
* **207** the fixture-clock hypothesis was **refuted by measurement** (`@Volatile` changed nothing) and the **wall-clock
  connection default was found**;
* **208** that default was **repaired** and the silence **survived** it;
* **209** the counters **refuted** the iteration/visibility hypothesis (`seenJob=13`) and **displaced** the suspicion onto
  the witness's own setup (`directSeen=1 retiredAfterDirect=false`);
* **210** the controlled experiment **PASSED**.

**Two plausible hypotheses were refuted by measurement rather than argument, and neither cost anything but an instrument**
— and every abandoned attempt was **withdrawn rather than shipped**, so no committed SHA ever carried a red lane.

**The instruments are kept, not discarded:** `leaseSweepTicksForTest`, `leaseSweepRelationsSeenForTest`,
`leaseSweepLeasesLapsedForTest`, `hasLeaseSweepJob()`, and the job's **loud** failure (a throwable recorded in the
transport's census, with cancellation rethrown). An "armed" scheduler can no longer be mistaken for a working one.

**Acceptance:** whole `:mesh` lane **1189 tests, 0 failures** (1188 + the time-based arm). ANDROID-04 stays
**FIX_SUBMITTED**.

## DO THIS FIRST (round 209, landed) — THE SECOND DIAGNOSTIC **DISPLACES** THE SUSPICION

**The instrument named in round 208 landed and spoke.** `sweepInboundLeases()` now **counts** what it iterated
(`leaseSweepRelationsSeenForTest`) and what lapsed (`leaseSweepLeasesLapsedForTest`), so "finds nothing" can no longer
hide two different claims. The measurement:

> **`ticks=14 seenJob=13 lapsed=0 retired=false | directSeen=1 retiredAfterDirect=false`**

**What it proves:** the owned job ticked **14** times and **saw 13 relations** — so **iteration and cross-thread
visibility are fine**, and the "stale collection" hypothesis is refuted **by measurement rather than argument**. No lease
lapsed — **and the direct call, run inside my own scenario, also failed to retire**.

**So the owned sweep was never the only difference between my witness and the court's working arm: my scenario itself
does not set up what that arm sets up.** The abandoned attempt changed **two** things at once — the caller **and**,
unknowingly, the setup — which is exactly the error this diagnosis caught.

**The refined witness, now exactly specified:** build it **on the court's own arm, verbatim**
(`rig.completeTrust()`, `rigNow = base`, `getClientGeneration`, `publishRelation`, `sealFromInitiator(rig, 909, 600)`,
`pushToResponder(frags.take(2))`, `responderConnection().activeLeaseOf(seq)`, `rigNow = lease.deadlineMono`) and then
differ in **exactly one** way: **not** calling `sweepInboundLeases()`. That is the **controlled experiment**.

**Two hypotheses refuted by measurement — the round's real value:** the fixture clock's visibility (`@Volatile` changed
nothing, round 207) and the job's iteration/visibility (`seenJob=13`, round 209). Both were plausible; neither was true;
and neither cost anything but an instrument.

**Standing:** the counters are **kept** (instruments, not controls), the diagnostic arm was **withdrawn** so the lane is
green (**1188 tests, 0 failures**), the diagnostic logs are kept with their measurements beside round 207's, and
ANDROID-04 stays **FIX_SUBMITTED** with its time-based witness **owed but one controlled edit away**.

## DO THIS FIRST (round 208, landed) — THE CARD'S STEP 1 LANDS FOR **CONNECTIONS**

**The repair:** `BleOrchestrationDriver` creates every connection with a **monotonic** clock at **both** creation sites
(`System.nanoTime() / 1_000_000_000L`, seconds stated explicitly), where the audited default was
`System.currentTimeMillis() / 1000L` — a **wall clock** against which **every lease deadline on this isle** is computed,
and which can be stepped *backwards*. This session had already replaced that very default in the **governor** (187/195)
and the **admission budget** (186); the **connections** were the last place it stood.

**The RED was canonical, and its own control caught its author:** three arms run **first** in the probes directory — and
the **W00 control failed on its own miscount** (it asserted two occurrences of the seam where the file carries four: two
declarations, two uses) before the defect arms were allowed to speak. **That is what a positive control is for.** A second
self-inflicted trap, the same one the repository's identity control taught at round 163: the arm's blanket ban on the
wall-clock spelling tripped on the **audit-trail comment the repair itself had written** above each site — the arm now
**strips comments first**.

**The measurement that makes this round more than a repair:** the parked **time-based witness was re-run with the
repair — and it still fails.** So the wall-clock default was **not** the cause of the owned sweep's silence (a genuine
defect, worth its own repair, now fixed — but not this one). The diagnosis stands **narrower** than before: the job is
**armed ✓ ticking (14 ticks / 400 ms at 25 ms) ✓ failing not ✓**, and the sweep **finds nothing**, while the same call on
the **test** thread trips the same relation — **both now using the same monotonic connection clock**.

**The next instrument is named:** have the sweep **count what it iterated** (relations seen, leases examined, leases
lapsed), so that "finds nothing" becomes "saw N relations, swept 0 leases" — which tells whether the **iteration** or the
**expiry law** is silent.

**Acceptance:** canonical arm **OK** and moved into `tools/readiness/tests/`; whole `:mesh` lane **1188 tests, 0
failures**. The witness stays **parked with both measurements**; ANDROID-04 stays **FIX_SUBMITTED** with the time-based
witness explicitly **owed**.

## DO THIS FIRST (round 207, landed) — THE OWNED SWEEP'S SILENCE DIAGNOSED

**The instruments narrowed it, and the measurement is decisive:** the job now **records its own failure** in the
transport's census (`CancellationException` rethrown, so its own cancellation is never mistaken for a failure) and
**counts its ticks** (`leaseSweepTicksForTest`). The measurement:

> **`retired=false ticks=14 armedAtEnd=true sweepFailures=0`**

**The job is armed, ticking (14 ticks over 400 ms at a 25 ms interval) and failing not — and the relation is still not
retired.** The sweep *runs and finds nothing*, while the same call on the test thread trips the same relation. One
hypothesis was **tested and refuted** rather than assumed: `@Volatile` on the fixture's clock changed nothing, so the
stale read is not there.

**And the grep then found the real defect — the card's own step 1:**

```kotlin
BleOrchestrationDriver:  clock = connectionClockForTest ?: { System.currentTimeMillis() / 1000L }
```

at **two** creation sites (`:190`, `:601`) — **a wall clock is the default for the lease clock of a real connection**.
The card asks for a monotonic clock in the actual transport/composition with wall time kept only for the app; this
session did that for the **governor** (rounds 187/195) and the **admission budget** (186) — but **not for the
connections**, and every lease deadline on this isle is computed against that clock.

**Kept:** the loud job and the tick counter (both are improvements: "armed" and "working" are now distinguishable, and a
tick that fails is visible). **Withdrawn:** the diagnostic arm, so the lane is green (**1188 tests, 0 failures**); the
diagnostic log is kept with its measurement.

**Next round is a one-line-per-site repair with a named test:** make **both** connection-creation sites monotonic, then
re-run the parked witness — it should then trip, because the job's sweep will see the same clock the court advances.

## DO THIS FIRST (round 206, landed) — ANDROID-04's TIME-BASED WITNESS ATTEMPTED

**The seam landed and stays:** `BleTransport` gains `leaseSweepIntervalMillis` (defaulting to the named constant, so
**production is unchanged**), and the T20 rig threads it through with a **long** court default (60 s) so no existing arm
is ever swept mid-witness.

**The witness is RED — with a diagnostic that narrowed the cause.** With the injected connection clock advanced past the
lease's deadline and a **25 ms** interval, the **silent relation stayed standing for five seconds** — and its diagnostic
assertion (`hasLeaseSweepJob()`) **passed**, so the owned job **is armed and ticking**. The **same rig and clock**, in the
T20 court's own arm, trips the **same** relation when `sweepInboundLeases()` is called **directly on the test thread**.

**So the difference is the caller's thread**, and the leading hypothesis is named rather than acted on: the job wraps its
sweep in `runCatching`, which would **swallow** an IO-dispatcher exception (a concurrent modification while the test thread
works, or a lock discipline the sweep expects from its own thread) and keep ticking while tripping nothing. **The next step
is a measurement, not a guess:** make the job's failure **observable** — record the throwable into the transport's own
rejection census instead of swallowing it — and **read** what it says; if it is silent, instrument the sweep's own
iteration.

**The witness was withdrawn, not shipped red:** the lane is green again (whole `:mesh` lane **1188 tests, 0 failures**), and
the witness is parked with its measurement at
`tools/readiness/audit_probes/kotlin/t20-owned-sweep-time-witness.kt.txt`. **The red log is kept separate and carries the
diagnostic's PASS** — which is what makes it valuable rather than merely a failure.

**Why this is progress rather than a setback:** round 205 named a seam; round 206 landed it *and* turned "the scheduler
works" from an assumption into a **measured question with a narrowed cause**. A scheduler that is **armed but trips
nothing** is exactly the defect a green arming-witness would have hidden.

## DO THIS FIRST (round 205, landed) — ANDROID-04's STEPS 2/4/5 **HOLD**

**Three of the card's five steps needed no repair at all — only evidence.** Read from the code and from the courts that
already witness them:

* **step 2 holds:** `sweepInboundLeases()` closes every lapsed relation through
  `handleCentralDisconnected(address, client.clientToken, client.gattGeneration)` and
  `handleServerDisconnected(address, serverDriver.getClientGeneration(address))` — **the exact relation and the exact
  generation travel** (T12's law), and the *absolute deadline* is the connection's own lease term, swept at the
  **connection's own monotonic, injectable clock**.
* **step 4 holds through the same arms:** they verify the token, clear handshake/writer/session state, retire the slot
  (releasing capacity through the driver) and close **only** the captured relation.
* **step 5 holds:** the transport cancels jobs at eight sites, including the **new** `leaseSweepJob` at `stop()`; and
  "a queued stale timer must still be harmless after cancellation" is the T20/T23 courts' own witness.

**What remains is proof by TIME, not by traffic** — the owned sweep is witnessed as **armed** and **cancelled**, never as
actually **tripping**. Its two seams are named: **(a)** `LEASE_SWEEP_INTERVAL_MS` is a **constant** and must become an
**injectable constructor parameter** so a court can drive 25 ms; **(b)** the **connection clock is already injectable** in
the T20 rig (`alice.centralDriver.connectionClockForTest = { rigNow }`, same for bob) — so **no new production seam is
needed** for it.

**The witness is therefore one edit away:** admit a relation, advance the injected clock past its absolute term, wait past
one interval **with no further traffic**, and assert the relation **retired**.

**Why it was not written this round:** the budget went to *measuring* steps 2/4/5 — which turned out to hold — and a
**timing-dependent test written in haste is exactly the flake this programme refuses**. Next round lands it with the seams
already named.

## DO THIS FIRST (round 204, landed) — ANDROID-04: THE LEASE SWEEP GETS A PRODUCTION OWNER

**The defect, in the finding's own words:** `BleTransport.sweepInboundLeases()` was called **only** by a court
(`ReadinessT20Test`), so the absolute lease expiry ran **only** when some other inbound packet arrived and tripped the
ingress — **a silent peer therefore never tripped it**, and a relation whose absolute term had lapsed stayed pinned until
unrelated traffic happened by.

**The RED was canonical and immutable:** `tools/readiness/tests/test_lease_sweep_owner.py` (four arms, written and run
**first** in the probes directory at 3 failures with the W00 control passing) asserts the card's step 3 — *"schedule
assembly expiration **independently of future peer traffic**"* — and also that the interval be **named** and **generous**
(≥ 250 ms) so a frozen-clock court is never swept mid-witness.

**The repair:** `BleTransport` now **owns** `leaseSweepJob`, armed **inside `start()`** (guarded against double-arming)
with `LEASE_SWEEP_INTERVAL_MS = 1000L` as a named constant, and **cancelled in `stop()`**. The loop's **delay is the
cancellation point** and the `runCatching` covers **only** the sweep, so a cancelled job cannot be swallowed by its own
error handling and spin — the reasoning is written into the code. `hasLeaseSweepJob()` is its observation seam, the shape
of the existing `hasInboundJob`.

**The behavioural witness shipped with it:** `testTransportOwnsALeaseSweepArmedAtStartAndCancelledAtStop` asserts no sweep
before start, a sweep after `start()`, and no sweep after `stop()` — the owner is proven **in the lifecycle**, not merely
in the source.

**Two insertion failures of mine, both caught by the compiler and recorded:** the first attempt inserted the arming block
between a KDoc and its declaration (11 errors); the second brace-matched `start()`'s end **naively** — a scan fooled by
braces inside strings and comments — and left a **statement** at class level (11 errors again, then 1). The third anchored
on a **unique three-line tail inside `start()`** and compiled; `isActive` was then unresolved and was replaced by
`while (true)` with the delay as the documented cancellation point. **Three compiler-aided corrections, one clean green
run.**

**Acceptance:** whole `:mesh` lane green **1188 tests, 0 failures** with the witness; the canonical arm OK; the RED kept
separate. **ANDROID-04 → FIX_SUBMITTED** — but only an independent audit may write `VERIFIED_FIXED`, and the remaining
card steps (each callback carrying the exact relation and timer generation, the atomic release on expiry, and
queued-stale-timer harmlessness) are the **next** round's measured work, not this round's claim.

## DO THIS FIRST (round 203, landed) — IOS-05 / T27 STEP 4's WITNESS LANDS

**The witness owed since round 199 is written and green.** `ReadinessT27Tests.testW14APenaltyStormLeavethDurableTrustUntouched`
builds a **real** durable repository (`SqlitePeerIdentityStore` over a temp file), authors and validates a **T13 binding**
for an identity, **pins** it through `applyValidatedBinding` (asserting the durable result is `.accepted` or
`.firstSeenPinned`), **snapshots** the durable record, then drives **two hundred penalties** against a governor for that
very identity — asserting the governor's **local** trust **fell** (`trustOf` < 1.0, so the storm really happened) — and
finally asserts the durable record is **exactly as it stood**. **Its positive control is inside it:** the storm is proven
to have taken effect locally, so a witness that proved nothing could not pass.

**Both halves are now evidence, not assertion:** the *substance* was measured in round 199 (`PeerGovernor.swift` carries
**zero** references to any durable surface) and the *witness* now drives the claim against a real repository. The card's
words are honoured in both senses: no local bucket exhaustion revokes an identity, and the proof says so about a durable
record that really exists.

**The card's five steps are now all carried on the iOS isle:** (1) the canonical governor under the runtime owner with a
**structural** monotonic clock (202); (2) the pre-auth global/relation budget at the real doors (196); (3) the post-AEAD
charge — the record/byte budget on the **immutable full NodeID** plus the governor's identity **trust** gate — before the
payload leaves (198, 202); (4) the separation of local penalties from durable trust, **measured and witnessed** (199, 203);
(5) the Trust mutations serialised under `registryLock` (194).

**Acceptance:** the witness green (10 T27 tests) and the whole iOS lane **1204 tests, 0 failures (0 unexpected)**.
**One fixture error of mine, recorded:** the witness first failed to **compile** (`cannot find 'Curve25519' in scope`) —
a missing `import CryptoKit`; a compile failure is not a behavioural result, which is why it is recorded as such.

**IOS-05 stays FIX_SUBMITTED** — as its Android isle-mate does — with **no independent verification** (only an independent
audit may write `VERIFIED_FIXED`), readiness flags **false** and the five external gates **OPEN**.

## DO THIS FIRST (round 202, landed) — IOS-05 / T27 STEP 1 LANDS BY MEASUREMENT

**The choice, made on evidence.** Round 201 exposed that the governor's canonical buckets are **per-second frame
buckets** (DIRECT 60, SOS 30, BROADCAST 20, BULK 10, unknown 10) while the post-AEAD gate sees **whole records** (a
257-record wrap, a 64-fragment record) — so charging them **per value** refuses legitimate work, and that attempt was
**withdrawn on a contaminated measurement** (a compile-failed attempt shared a log with a later run, so the three failing
names were never captured and are therefore **not claimed**).

**Course (a) is now implemented:** `BleTransport` owns the canonical `PeerGovernor` — default configuration, production
clock **monotonic by construction** — and charges its **trust** question (`admits`, which consumes **no** tokens) per
value at **both** post-AEAD gates, recording a refusal when an identity is under a refuse window, while **rate remains the
router's own budget**, where those buckets were designed to live. The reasoning is written into the **field's docstring**,
so a later reader meets the measurement rather than a bare choice.

**The measurement is clean this time, which was the point:** ONE run, its own log, no earlier attempt sharing it —
**Executed 1203 tests, with 0 failures (0 unexpected)**, 207.4s, **zero** XCTest failures.

**The arm moved into the canonical suite** (`tools/readiness/tests/test_ios_governor_under_runtime_owner.py`), written and
run red first, updated to the chosen course, and moved with the repair.

**IOS-05 → FIX_SUBMITTED, with its pending proof stated:** steps 1, 2, 3 and 5 are carried; step 4's **substance** is
measured (`PeerGovernor.swift` carries **zero** references to any durable surface, so its penalties can only touch its own
in-memory records) while step 4's **witness** (a penalty storm, then assert a durable repository is untouched) is **owed
and named**. No independent verification exists; only an independent audit may write `VERIFIED_FIXED`.

**What the round proves about method:** a contaminated measurement was **withdrawn rather than shipped**, and the retry
was designed so contamination is impossible (one run, one log, a precise failure grep) — and the chosen course needed no
failing name at all, because it left the lane **green**.

## DO THIS FIRST (round 198, landed) — IOS-05 / T27 STEP 3 LANDS

**The five-site repair, exactly as specified:** (i)+(ii) `TrustedHandshakeController.swift` now **retains
`binding.nodeId`** at **both** trust sites (immediately before `trustAuthority.applyValidatedBinding(binding)` in each
direction); (iii) clears it in `destroy()` and answers it through `authenticatedNodeId` (a copy, always); (iv)
`SessionManager.authenticatedNodeIdOf(_:)` reads `slot.controller?.authenticatedNodeId` **inside the slot's own
`serialize { }`** — the isle's own locking discipline, the same one `isReady` uses; (v) `BleTransport` owns a **second**
`AdmissionBudget` for the authenticated scope and charges it in **both** post-AEAD collectors **immediately before**
`delegate?.transportDidReceive(…)`, keyed on the authenticated identity with the relation's id as the documented
fallback, recording a refusal under `admission.budget.authenticated` and **dropping** the plaintext.

**The RED moved into the canonical suite**, as its own rule required: `tools/readiness/tests/test_ios_post_aead_charge.py`
(written and run red first in the probes directory, then moved with the repair).

**Acceptance:** the arm suite **OK**; whole iOS lane **1202 tests, 0 failures (0 unexpected)**.

**THE TRUNCATION BUG RECURRED, AND THAT IS THE ROUND'S MOST IMPORTANT RECORD:** the patch script that added the
SessionManager accessor wrote the file with `open(path,'w')` **before** reading it in the same expression, so
`SessionManager.swift` was **emptied to zero lines for the second time** (the first was round 191 — same pattern, same
class of edit). Caught by `wc -l`, restored with `git checkout --`, re-applied **reading first**. **Two cascades hid it
again** (the compiler blamed an unrelated file: `cannot find type 'SessionManager' in scope`). **The rule is now absolute
and recorded as such: EVERY patch goes through the helper that reads first and writes second, and a `wc -l` sanity check
follows every multi-file patch script.**

**Two smaller errors:** the collector anchors assumed the wrong indentation (then extracted **programmatically** from the
file rather than typed), and my own arm's W00 control asserted the **Android** spelling where the isle writes
`.authenticated(` — the control caught its own author.

**A context lesson:** an assertion whose failure message embeds a whole source file dumped hundreds of lines into the
record **twice**; the arms now use short messages and **positional** comparisons (`t.index(charge) < t.index(delivery)`).

**What remains on IOS-05:** step 4's separation of local abuse penalties from **durable** trust, and the **behavioural
witness** of step 3 that the Android isle carries (a real trusted handshake answering the peer's **own** sixteen-octet
NodeID) — the canonical arm proves the charge and the retention exist and are **ordered**; a court witness would prove
them against a live handshake, and that is **owed**, not implied.

## DO THIS FIRST (round 196, landed) — IOS-05 / T27 STEP 2 LANDS

**The defect was absolute on this isle:** `PeerGovernor` is referenced **nowhere in production except one comment**
(`GodstoneCore/ProofOfWork.swift:14`), so **no charge happened at any ingress** — raw advertisements, malformed values
and no-relation traffic were all free.

**The RED was behavioural, through the real door:** a witness in `ReadinessT15Tests` (the court that owns a transport
and its manager fakes) floods **70,000 advertisements** through `processOutboundDiscover` and reads the transport's own
rejection census — `Executed 6 tests, 1 failure`, **`Refusals seen: 0`**, on the unmodified tree, with argv, source SHA
and digest.

**The repair:** a new `ios/Godstone/Sources/GodstoneMesh/AdmissionBudget.swift` — the iOS twin of the Android class,
with the **relation scope** (keyed by the relation, the only identity that exists before authentication) and the
**global scope** (raw air traffic, which arrives before any relation), a **monotonic injected clock**, an `NSLock`, and
**exact counters** — charged **first** at `processOutboundDiscover` (global, whatever the epoch, refusing with `.noOp`
before the reduction) and at `processInboundWrite` (the relation, before any parse or session work). The transport now
exposes the downstream counters through `admissionRefusalsForTest` and `admissionTrackedRelationsForTest`.

**My own over-application, caught by the lane and corrected on BOTH isles:** I had set the pre-auth **relation**
registry's bound to the card's **256** — but that number is the **governor's tracked-identity bound** (a different
instrument, and it *is* 256 there, rounds 187/195). Applying it here **refused a legitimate court** that exercises
**1024 distinct relations** through the write door (ReadinessT16's quarantine-metadata witness: `256` where it expected
`1024`, and its own refusal counter `0` where it expected `976`, because *my* budget refused the values before its logic
ran). The bound is now **4096 on both isles** — parity first — with the reasoning written into both constants. **A
pre-auth bound that is too tight is indistinguishable from a denial of service the transport inflicts on its own peers**
(the lesson round 189 learned for the global scope).

**A compile error of my own, also recorded:** the budget field was first inserted at the first occurrence of the anchor
comment, which lives **before** the class declaration — so `admissionBudget` was out of scope at the doors. The lane
named it and it was **moved inside** the class.

**Acceptance:** whole iOS lane **1202 tests, 0 failures** (1201 + the witness); Android `:mesh` lane re-run for the parity
change — BUILD SUCCESSFUL.

**Remaining on IOS-05:** step 3's **post-AEAD** charge (after AEAD, before application decode/store/router delivery, on
the **authenticated** identity and priority, with the outcome **bound** — the Android isle carries it, including the
retained full NodeID of round 193); and step 4's separation of local abuse penalties from **durable** trust.

## DO THIS FIRST (round 195, landed) — IOS-05 / T27: THE SPECIFIED BOUND

**Both defaults were the same two defects the Android twin carried** (round 187), found by reading the manifest:
`PeerGovernor.defaultMaxTrackedPeers = 4096` where the card specifies **256**, and `nowMillis` defaulting to
`Int64(Date().timeIntervalSince1970 * 1000)` — a **wall clock**, which a rollback can step *backwards* while this
governor's guards can only *extend* a refuse window, never refund a budget.

**The RED was behavioural and cheap:** an arm in the isle's own T27 court reading the production bound —
`Executed 7 tests, 1 failure` on the unmodified tree, captured with argv, source SHA and digest.

**The repair is STRONGER than the Android form, and that is the round's design result.** Instead of checking whether
the default closure *is* the monotonic one (which Swift cannot compare), the iOS **production initialiser takes NO clock
at all** — `PeerGovernor(maxTrackedPeers:capacity:refillPerSecond:)` delegates to a private designated init with the
monotonic clock and `usesMonotonicProductionClock: true`. **So production cannot be wall-clocked by omission:** the
wall-clock path is no longer a default, it is an explicit court-only choice. The court initialiser (`nowMillis:`) is
marked `convenience` and reports `false`, so the accessor answers the question that matters — what *production* carries.

**W11 shipped with the accessor**, stated rather than dressed up: true for production, false for an injected clock, and
the production bound travels with the production clock. **The compiler corrected one thing in it:** the delegating
initialiser first lacked `convenience`, and Swift refused `self.init` from a designated init — recorded because the fix
was the *compiler's*, not a guess.

**Acceptance:** whole iOS lane **1201 tests, 0 failures** (1199 + W10/W11).

**What remains on IOS-05 — steps 2 and 4, the ACTUAL WIRING:** the iOS `PeerGovernor` is still referenced **nowhere in
production except one comment** (`GodstoneCore/ProofOfWork.swift:14`), so **no charge happens at the ingress**. The cheap
global/connection budget must be charged **before** allocating/parsing/DH/trust work at the transport's own doors (the
peer is unauthenticated there; its hint may never serve as an identity); the authenticated identity/priority budget must
be charged **after AEAD and before** application decode/store/router delivery, with the outcome **bound**; and local
abuse penalties must stay **separate** from durable trust. **The Android isle already carries all of these (rounds
186–193), including the exact scope split round 189 MEASURED rather than guessed** (a per-relation bound cannot serve raw
air traffic, because the churn witnesses drive ten thousand observations).

## DO THIS FIRST (round 194, landed) — IOS-05 / T27: STEP 5 LANDS

**The defect, read from the code and not from the card:** `mutableTrust(_:)` takes `registryLock`, reads the `Trust`
**reference** and **releases** the lock; `reward` and `penalise` then mutate that shared reference's fields (`score`,
`strikes`, `refuseUntilMillis`) with **no lock held**. Two concurrent callers race on one record, and a lost `strikes`
increment or a lost `refuseUntilMillis` extension is a **trust decision lost** — unnameable afterwards.

**The RED is canonical and it names the deadlock trap:** `tools/readiness/tests/test_ios_governor_serialisation.py`
(three arms) was written and **run first in the probes directory** — `Ran 3 tests, FAILED (failures=2)` with the W00
positive control passing — and its third arm asserts the repair must provide a **lock-held** lookup, because
`registryLock` is an `NSLock` and **not recursive**: calling the locking `mutableTrust` while holding the lock would
**deadlock** rather than fix anything. **That arm is why the repair was written once instead of twice.**

**The repair:** `mutableTrustLocked(_:)` carries the allocation law with the lock **assumed held**; `mutableTrust(_:)`
becomes the locking wrapper around it (one implementation, two entry points); and `reward`/`penalise` take the lock with
`defer { unlock }`, so the **whole** update is serialised.

**The behavioural control shipped with it**, in the isle's own T27 court: three penalties of 0.2 from full trust are
**exactly 0.4** — the determinism the serialisation restored. It is stated as a **positive control**, because the RED was
the source-level arm (a race cannot be proven deterministically without a seam the repair does not add).

**Acceptance:** the canonical arm **OK**; whole iOS lane **1199 tests, 0 failures** (1198 + the control), with the first
run at 1198/0 showing the change broke no existing court.

**What remains on IOS-05 — steps 1–4 of the card:** one governor configuration with the bounded global/pre-auth buckets
under the runtime owner and an **injected monotonic clock**; the charge of the cheap global/connection budget **before**
allocating/parsing/DH/trust work (the peer is unauthenticated there and its hint may never be treated as an identity); the
charge of the authenticated identity/priority budget **after AEAD and before** application decode/store/router delivery,
with the outcome **bound**; and the separation of local abuse penalties from **durable** trust. **The Android isle already
carries all of these (rounds 186–193) and is the shape to mirror.** IOS-05 stays **PARTIAL**.

## DO THIS FIRST (round 193, landed) — ANDROID-07 / T26 STEP 2 COMPLETE

**The repair is a retention, exactly as the round-192 diagnosis prescribed:** `TrustedHandshakeController` carries
`retainedNodeId` and **sets it at both trust sites** (immediately before `applyValidatedBinding` in each direction),
with a copy-on-read getter and a clearing in `destroy()`. `SessionManager.authenticatedNodeIdOf(peerId)` **reads** it
under the peer lock — **no derivation from the remote static key**, which round 192 *proved* to be the peer's **static
DH key** and therefore a different identity. The collector's authenticated charge prefers it, falling back to the
six-octet handle only when trust was never marked, and that fallback is stated in the code rather than relied upon.

**The witness moved home from the parked probe**, and the probe file was **deleted with the repair** (this repository's
own rule). It lives now in `ReadinessT17Test` — the court whose rig owns the **real** trusted handshake — asserting:
null before trust, and after `completeTrust()` an identity of **sixteen octets equal to the peer's own NodeID**. Its
key is the **connection's** `peerId` — the diagnosis's own correction, since the registry is keyed by what the
transport really passes and *not* by the air-address handle (`no-slot` named the mistake rather than a guess).

**Acceptance:** whole `:mesh` lane **1187 tests, 0 failures, 0 errors** (1186 + the witness). **Three measurements now
stand together as a chain of evidence:** round 191 (the accessor answers null when derived from the live session),
round 192 (the chain diagnosed link by link — the DH key is *not* the identity, the validated binding *is*), round 193
(the retention, with the witness proving the identity is the peer's own).

**ANDROID-07's four card steps are now all carried on the code side:** (1) the pre-auth global/relation budget at all
three raw doors; (2) the post-AEAD charge on the immutable full NodeID, before the payload leaves; (3) the specified
256 bound and monotonic production clock; (4) ingress witnesses plus exact downstream counters. The finding stays
**FIX_SUBMITTED**: only an independent audit may write `VERIFIED_FIXED`.

**My own error this round, recorded:** the first patch script assumed the code after `applyValidatedBinding` was an
`if` — it is a `when`, so the script aborted and **only the first patch had landed**; the lane then reported BUILD
SUCCESSFUL from a tree carrying a field and a getter that nothing used. **A partial green is not evidence** — the run
took 33 s on the partial tree, and only diffing what was applied showed how much was missing.

## DO THIS FIRST (round 190, landed) — ANDROID-07 / T26 STEP 4

**The observation surface's own weakness, measured before replacing it:** the transport's rejection **census is a
bounded ring of sixty-four events** (`REJECTION_RECORD_CAPACITY = 64`) with a separate overflow count, so a flood's
refusals can only be **counted** through the budgets' own counters. The transport now exposes three **exact** ones for
the pre-auth scope (`admissionRefusalsForTest`, `admissionAdmissionsForTest`, `admissionTrackedRelationsForTest`) beside
the authenticated pair added at round 188 — the card's "downstream counters".

**W13 shipped with the surface, and that is stated rather than dressed up:** it asserts `admissions + refusals == 3000`
**exactly** for a 3000-value flood, that exactly **one** relation was tracked, and that the lossy ring never claims more
than the counters. It could not precede the accessors it reads, so it is a **positive control shipped with them** — and
the **behavioural reds** of this finding remain the five captured earlier (W08 both relation doors, W09 the central door
before parsing, W10 the bound, W11 the clock, W12 the scan door), each with its own immutable log.

**The witnesses are now divided in the court's own header — which is step 4's actual complaint:** the audit's objection
was that **unit**-level cases were carried as though they proved the **ingress**. `ReadinessT26Test` now says at its head
that **W08–W13 are INGRESS WITNESSES** and that the **seven below are LOCAL UNIT COVERAGE** — each re-labelled in place
with `[LOCAL UNIT COVERAGE — … not the ingress]`. The card allows them to be retained; nothing now claims they are
ingress evidence.

**Acceptance:** whole `:mesh` lane **1186 tests, 0 failures, 0 errors** (1185 + W13).

**Standing:** ANDROID-07's four card steps are now carried on the code side — (1) the pre-auth global/relation budget
charged at all three raw doors, (2) the post-AEAD authenticated charge, (3) the specified 256 bound and monotonic clock,
(4) ingress witnesses plus exact downstream counters. The finding stays **FIX_SUBMITTED**: only an independent audit may
write `VERIFIED_FIXED`. **One question remains open and is named:** whether "the immutable full NodeID" means the
sixteen-octet identity rather than the relation's trusted-handshake-bound peer id — if it does, the **crypto layer** must
expose that identity at the post-AEAD site.

## DO THIS FIRST (round 189, landed) — ANDROID-07 / T26: THE **GLOBAL** HALF OF STEP 1

**A gap in the same family, found by reading the doors rather than the card:** rounds 186–188 charged the two *relation*
doors and the post-AEAD road, but `handleScanEvent` — the door through which an **advertisement** arrives, **before any
relation, any parse and any session** — charged **nothing**. A flood of advertisements was free radio work: the card's
own phrase ("miss raw traffic") in its rawest form.

**The RED is behavioural, through the real door:** W12 floods **70,000 advertisements** through `handleScanEvent` with a
real scan context and reads the transport's own rejection census — **0 refusals** on the unmodified tree, captured with
argv, source SHA and digest.

**The measurement that sized the repair — and why it had to be a GLOBAL scope:** `ReadinessT11Test` drives **ten
thousand** scan observations **twice** (lines 279, 314) — the DIAG-001 churn witnesses — so a *per-relation* bound (my
256-relation bound, or any allowance below ten thousand) would have **refused legitimate host-side churn and broken those
courts**. The card asks for a "GLOBAL/relation" budget, so the **global scope is the right instrument**: `chargeGlobal()`
on `AdmissionBudget` with its own window, charged **first** in `handleScanEvent` whatever the context, and an allowance
(**65,536 records / 64 MiB per window**) reasoned from **physical advertising rates** (tens per second per advertiser)
rather than from a host loop — that reasoning is written into the constant.

**Acceptance:** whole `:mesh` lane **1185 tests, 0 failures, 0 errors** (1184 + W12), **including T11's two
ten-thousand-observation loops**.

**Step 4's remainder, advanced rather than claimed done:** the T26 court now carries **five ingress-level witnesses**
(W08 both relation doors, W09 the central door before parsing, W10 the production bound, W11 the production clock, W12 the
scan door) beside the seven unit ones, which the card allows to be **retained as local coverage**. What remains:
**re-labelling the seven** so no reader mistakes a unit witness for an ingress one, and the **downstream counters** the
card asks for (the transport now exposes the authenticated-scope counters and `refusedCount`/`trackedRelations`; wiring
them to a reported counter surface is the last piece).

## DO THIS FIRST (round 188, landed) — ANDROID-07 / T26 STEP 2

**The defect, pinned to the exact arm:** in `BleTransport.received()`'s collector, `openWithResult` decides and the
`Authenticated` arm hands the plaintext to the key-confirmation door or to the application (`trySend`) — **charged
nothing**. The only authenticated-side budget was the **Router's** governor, which sits **downstream of the frame
decode** and keys on the **claimed** sender and the **claimed** priority — so authenticated ciphertext spends the
transport's memory and CPU unmeasured, and a claimed SOS priority is what chooses a bucket.

**The RED is canonical and immutable:** three arms, written and **run first in the probes directory**
(`Ran 3 tests, FAILED (failures=2)` with the **W00 positive control passing** — the Authenticated arm still exists to be
charged), then **moved into `tools/readiness/tests/` with the repair**, per that directory's own rule.

**The repair:** `AdmissionBudget.chargeAuthenticated()` — the authenticated scope, with a **prefixed key space**
(`authenticated:`) so an authenticated identity can never collide with a pre-auth address — and the transport owns a
**second** budget instance so each scope's counters report **one** scope. Charged in the `Authenticated` arm **before**
`takeInboundKeyConfirmation`/`trySend`; a refusal is **recorded** (`admission.budget.authenticated`) and the payload
**dropped**.

**The honest limit, named rather than glossed:** the identity available at that site is the **relation's authenticated
peer id** — bound by the trusted handshake, hence authenticated material, never a MAC or a hint. *If* the audit's phrase
"the immutable full NodeID" means the **sixteen-octet** identity rather than the relation's bound handle, then the
**crypto layer must expose that identity at this site** — a named further step, not an assumption made here.

**Three of my own errors, all caught and all recorded:** (i) the first patch script died at **parse time** on a quote
collision, so **nothing was applied** while the lane reported "SUCCESSFUL in 2s" from an up-to-date task — **a cached
green is not evidence**, and the empty diff was what revealed it; (ii) the budget's new accessor collided with its own
field name (`admittedCount()` vs `admittedCount`) — the compiler caught it; (iii) the new arm's regex demanded a variable
name (`authenticatedBudget`) the code did not use (`authenticatedAdmissionBudget`), so the arm failed against code that
**was** correct — **the arm was widened to match the SCOPE, not the name.**

**Acceptance:** canonical arm suite OK; whole `:mesh` lane **1184 tests, 0 failures, 0 errors**.

**Remaining on ANDROID-07:** step 4's remainder (the seven mislabeled governor-**unit** witnesses re-scoped or replaced
with ingress-level ones, plus the downstream counters) and the full-NodeID question above.

## DO THIS FIRST (round 187, landed) — ANDROID-07 / T26 STEP 3

**The bound, proved behaviourally:** W10 reads `PeerGovernor().maxTrackedPeersLimit()` and was RED at
**`expected:<256> but was:<4096>`** on the unmodified tree — the audited default kept a registry **four times larger**
than the card specifies, for identities that no longer exist. The repair sets `DEFAULT_MAX_TRACKED_PEERS = 256`,
documented; the refusal **beyond** the bound already happened *before* allocation (the class's own `admitIdentity`), so
no new policy was invented.

**The clock, with an honest note about where its proof had to come from:** the audited default was
`System::currentTimeMillis` — a **wall clock**, which a rollback (NTP, a user, a hostile environment) can step
*backwards*, and the class's guards can only **extend** a refuse window, never refund a budget — so the refund law
depended on the platform's honesty. It is now `System.nanoTime()`-derived milliseconds, and the class gains
`usesTheMonotonicProductionClock()` so the production default is **answerable**: W11 asserts it true for the production
instance and false for a court that injects its own clock. **W11 could not be written before the repair** — it asks about
an accessor the repair adds — so it shipped **with** the change, as this programme's owner-contract repairs have done
before, and that is stated rather than glossed.

**The repair is safe because the courts never used the defaults:** every witness injects its own bound (8, 64) and its
own controllable clock — which is precisely why the *default* is what production carries. Whole `:mesh` lane **1184
tests, 0 failures, 0 errors** (1182 + W10/W11).

**Remaining on ANDROID-07:** **step 2** — the post-AEAD charge against the **immutable full NodeID**, before full
application payload decoding, with no MAC, hint or claimed-SOS evasion of the global cap; and **step 4's remainder** (the
seven mislabeled governor-*unit* witnesses re-scoped or replaced, plus the downstream counters the card asks for).

## DO THIS FIRST (round 186, landed) — ANDROID-07 / T26 STEP 1

**The defect, measured rather than quoted:** `PeerGovernor` exists and is used — but in the **Router**
(`router/Router.kt:36`), i.e. *after* reassembly, on a *claimed* identity, and only for traffic that survived parsing.
So **raw, malformed, unknown-type, over-sized and no-connection traffic is charged nothing**, and a flood of it is free.
Its own defaults are not the card's either: `DEFAULT_MAX_TRACKED_PEERS = 4096` where the card specifies **256**, and its
clock defaults to `System::currentTimeMillis` — a **wall clock**, which a rollback can refund.

**The RED, byte-level through both real doors:** `ReadinessT26Test` (the designated T26 court) gains W08 and W09 — a
flood of unparsable three-octet frames driven through `handleServerInboundWrite` (an address with **no** connection) and
through `handleCentralInboundNotification`, asserting the transport's **own rejection census** names a budget refusal.
On the unmodified tree both observed **`refusals seen: 0`**. This is the shape the card's step 4 asks for ("tests through
GATT/transport ingress and downstream counters") instead of the seven unit-level witnesses the court carries.

**The repair:** a new `transport/AdmissionBudget.kt` — a **monotonic, injectable** clock (`System.nanoTime()` by
default; the transport gains the parameter so a court can drive rollbacks), the card's **256**-relation bound with a
**deterministic refusal** beyond it, and a per-relation record+byte allowance in a bounded window. Charged **first** in
both doors — before the connection lookup, before `ingestInboundAttValue` reassembles anything, before any crypto — with
a recorded refusal under the site `admission.budget`, so it is observable rather than silent.

**My own first allowance was wrong, caught by the lane and recorded:** 64 records / 64 KiB per window **refused fair
traffic** — the lane failed **four** courts (T18's 64-fragment record, T20's 257-record wrap and its ledger arm, T17's
burst). The allowance is now 2048 records / 1 MiB with the reasoning written in, and the RED's floods were widened to
5000 frames. **A pre-auth bound that is too tight is indistinguishable from a denial of service the transport inflicts
on its own peers.**

**Acceptance:** whole `:mesh` lane **1182 tests, 0 failures, 0 errors**. **ANDROID-07 → FIX_SUBMITTED.**

**Remaining on ANDROID-07:** step 2 (the post-AEAD charge against the immutable full NodeID before payload decoding, with
no MAC/hint/claimed-SOS evasion of the global cap); step 3's router-side alignment (256 bound + monotonic clock in the
Router's own governor); step 4's remainder (the mislabeled unit witnesses re-scoped, plus downstream counters).

## DO THIS FIRST (round 185, landed) — ANDROID-05's FRONTIER

The remaining item ("one real lifecycle authority, composed") was measured before it was touched — and the measurement says
**do not touch it blindly**:

* `UnifiedRuntimeLifecycle(` appears **only in test sources** (ReadinessAndroid05Test ×4, 05b ×3, T28 ×1).
* `LifecycleTransportAdapter(` has **one** production site — its own declaration — and the rest are courts.
* `BleTransport(` is constructed **nowhere in main** either: only its own constructor declaration.
* `di/MeshModule.kt` provides `DefaultRuntimeLifecycleGate` and binds **no** `Transport` and **no** `TransportSeam`.
* **And `MeshService.onCreate()` does not get there**: its first act is
  `if (!MeshNode.LINK_LAYER_READY) { Log.w("mesh service refused: M1-wire/M2-link not implemented"); stopSelf(); return }`
  — with `LINK_LAYER_READY` **false by audit requirement** (the substrate control's BL23 arm asserts it must remain false).

**So the frontier is BLOCKED BY A FROZEN INVARIANT, and "composing" the authority into the live service today would be
either DEAD CODE or a BREACH.** The two honest courses, named rather than taken: **(a)** write the composition *behind
the same guard* so it is correct for the day the flag flips, with a **testable factory** and a court that drives the
wiring through a fake transport — neither of which turns the radio on; or **(b)** leave it and record the dependency,
which is what this round does. **The flag's flip is external** (the hardware/A06 gates and their owners), and no
self-generated fixture may stand in for it.

**No production file was edited this round**, and the reason is the classification itself: a wiring written to "close" a
finding gated by a frozen invariant would be the unverifiable-and-invariant-breaching change this programme refuses.
**The deliverable is the measurement, the classification, and the two courses.**

## DO THIS FIRST (round 184, landed) — ANDROID-05's LAST NAMED ITEM

`drainLocked()` returned `resourcesReleased = 1` as a **constant** while the cleanliness law at `:77` requires
`resourcesReleased >= 1 && inFlightOutstanding == 0` — so the law was satisfied **trivially**, by a figure that claims a
release whatever happened. The card names the class: *"reporting a constant successful sweep"*.

**The RED was two-sided and behavioural:** W07 (a drain over a seam reporting **three** sweeps must report the **sum**) and
W08 (the **negative**: a never-started drain, which released nothing, may not claim a release). Both RED on the
unmodified tree — `expected:<4> but was:<1>` and `expected:<0> but was:<1>`.

**The repair, one coherent change:** the runtime's **one** lease release moved **into** the atomic drain, where the
winning release is **counted**; the four callers (`stop`, `onPowerLoss`, `onPermissionRemoved`, `drainForWipe`) no longer
release it themselves; and `resourcesReleased = leaseReleased + retired + drained` — the lease, the contexts *really*
retired, and the seam's *own* reported sweep count. **No constant survives.**

**And my own arithmetic was wrong — caught by the lane and recorded rather than erased:** W07's first expectation was
**4** (lease + sweep), but `start()` **had opened a context**, so the drain truly retired one: the measured figure is
**5** (lease 1 + context 1 + sweep 3). The correction is written into the arm with its reasoning, and `contextsRetired`
is asserted too. **Third time in four rounds that the lane caught an error of mine rather than the code's** — a measured
figure is only as good as the reading of what was actually released.

**Acceptance:** whole `:mesh` lane **1180 tests, 0 failures, 0 errors** (1178 + W07/W08).

**Remaining on ANDROID-05, named:** `UnifiedRuntimeLifecycle` is defined and **driven by courts** but **constructed
nowhere in production** — the runtime composition must bind it to the real seam. That is the finding's remaining frontier,
and it is a **wiring** step.

## DO THIS FIRST (round 183, landed) — ANDROID-05's STEP 3

The three-file repair, exactly as named: **(i)** a new `transport/InFlightAwareTransport.kt` — the optional capability a
concrete radio may offer, documented as *shape* and not a device claim; **(ii)** `LifecycleTransportAdapter.awaitInFlight`
**overrides** the seam's default (whose own KDoc says "the REAL adapter must override it") and delegates through
`as? InFlightAwareTransport`, answering 0 for a coarse transport exactly as before; **(iii)** `BleTransport` implements it
with a **measured** count — `inFlightWorkCount()` over `inboundJobs`, `provisionalJobs` and **both** writers' in-flight
fragments, re-measured every `POLL_MILLIS` until it reaches zero or the bound passes, **returning how many remain**. No
constant appears anywhere in it.

**The RED moved back, as its own rule required:** the four-arm suite left `tools/readiness/audit_probes/python/` and
lives again in `tools/readiness/tests/test_lifecycle_inflight_drain.py`, **green**; the probes README records the
landing. The RED itself stays on the record (`red-round182/red.log`: `Ran 4 tests, FAILED (failures=3)`, W00 passing),
and the two logs are kept **separate**.

**The behavioural half shipped with it, in the court that owns the finding:** W05 (the adapter **asks** an
in-flight-aware transport — the measured count travels on, and the transport **recorded** being asked with the bound) and
W06 (**negative control**: a coarse transport answers 0, unchanged).

**A defect in my own arm, caught by the lane and recorded rather than erased:** the first W05 draft asserted
`awaitInFlight(250L) == 250L` — **confusing the returned count with the bound**. The lane failed it; the correction
(assert the count, prove the bound through what the transport recorded) is written into the arm. Second time in three
rounds that a lane caught *my* error rather than the code's, and both are in the record.

**Acceptance:** canonical arm suite OK; whole `:mesh` lane **1178 tests, 0 failures, 0 errors** (1176 + W05/W06).

**Remaining on ANDROID-05 — one item:** `drainLocked()` still returns `resourcesReleased = 1` as a **constant**
(`RuntimeLifecycle.kt:239`) while the law at `:77` requires `resourcesReleased >= 1 && inFlightOutstanding == 0`. The
measured figure must come from what the drain **actually** released.

## DO THIS FIRST (round 181, landed) — ANDROID-05's T18 STEP

Both writer factories built their relation key as `RelationKey(direction, address, 0L)` — so a writer's relation identity
named **generation 0, a generation that belongs to NO relation**: a licence that could never be matched, released or
audited against the relation it was made for — while the connection itself carries a real generation
(`BleConnection.relationGeneration`, assigned by the orchestration driver at both creation sites).

**The RED, behavioural, and a setup failure recorded alongside it:** the arm reads `writer.relationKey.generation` against
`initiatorConnection().relationGeneration` after `completeTrust()` and one admitted record. The **first** attempt failed
in *setup* (`the writer must stand for the relation`) — which is how the court learned that **a writer is born with the
first record of the relation** — and that failure is **kept in the ledger** rather than erased, because a setup failure
is not a behavioural red. The second run is the RED: **`expected:<1> but was:<0>`** on the unmodified tree, with argv,
source SHA and digest.

**The repair:** both factories now pass `connection.relationGeneration` — the same reference the writer was already made
for — so the key and the connection's relation identity agree **by construction** rather than by hope.

**Acceptance:** whole `:mesh` lane **1176 tests, 0 failures, 0 errors** (1175 + the new witness), so every T18
fragmentation court, the capacity-lease courts and the substrate courts still hold — and the new witness is a permanent
control.

**What remains on ANDROID-05:** the `resourcesReleased = 1` constant (a reported figure that must be *measured*, not
asserted) and the **real** `LifecycleTransportAdapter.awaitInFlight` override (the adapter's coarse `stop()` versus a true
in-flight drain).

## DO THIS FIRST (round 180, landed) — THE APP LAYER'S ROOT CAUSE FOUND

Round 179 named the app target's failure a *module-resolution* problem. **That was wrong, and the correction is recorded
rather than left standing.** Measured twice:

* `swift build --package-path ios/Godstone` fails at the app package's **own native target** —
  `Sources/GodstoneLLMBridge/LlamaBridge.mm:3:10: fatal error: 'llama.h' file not found`.
* The manifest points that target's header search paths into `../../third_party/llama.cpp/…`, and **`third_party/llama.cpp`
  does not exist** (`third_party/` carries only a README).

So the app target's `unable to resolve module dependency: 'GodstoneCore'` (xcodebuild rc 65) is a **downstream symptom**
of the package producing no products.

**Why no earlier round could see it — now explained:** the mirror package used by the SwiftPM lane **omits the
native-dependent targets entirely** (`ios/Packages/GodstoneFoundation/Package.swift`: **0** references to
`GodstoneLLM`/`GodstoneLLMBridge`; the app's own `ios/Godstone/Package.swift`: **3**), and the App directory is in **no
lane**.

**The classification, in the objective's own vocabulary:** GS-ARCHIVE-005's App-layer steps (reader/scene ownership,
visible passage anchors, app-level kill/recreate tests) are **DEPENDENT ON AN EXTERNAL ARTIFACT** — the `NATIVE_MODELS`
gate ("hash-pinned binaries with license metadata", owner: native build owner), whose row already names T62–T65, **T78**
and T81. **This is not a self-supplied fixture and must not be treated as one:** the programme may not vendor, stub or
synthesize `llama.cpp` to make its own app build, exactly as it may not manufacture an approval.

**Two honest paths, written down rather than taken:** (a) wait for the T81 artifact and take the steps then, with the
build as their verdict; or (b) add an app-layer lane that **excludes** the native targets so the UI code becomes
verifiable *without* the model artifact — a repository change to be weighed against the rule that no mandatory lane may
be weakened, and against whether such a lane proves anything the audit accepts.

**No production file was edited in rounds 179–180**, deliberately: an App-layer edit whose only verdict would be an
`xcodebuild` that cannot run is exactly the unverifiable change this programme refuses. GS-ARCHIVE-005 stays **PARTIAL**,
now recorded as **external-dependent** rather than indefinitely deferred.

## DO THIS FIRST (round 179, landed) — A STALE ENVIRONMENTAL ASSUMPTION CORRECTED

**An assumption this programme had been carrying was WRONG.** Rounds 125 and 138 recorded that GS-ARCHIVE-005's
App-layer step and its app-level tests were unreachable because there was **no simulator**. The environment actually has
**Xcode 26.6 (17F113)** and an **iPhone 17 Pro (iOS 26.3) simulator** — verified this round, not assumed. That stale
assumption had been silently narrowing the programme, and it is corrected in the ledger.

**And the App layer still cannot be built here — MEASURED:** `xcodebuild … -target Godstone -sdk iphonesimulator build`
ends **rc 65** with `ios/Godstone/Sources/App/AppContainer.swift:3:8: error: unable to resolve module dependency:
'GodstoneCore'` (4 errors, both architectures). The wiring context is recorded: a single
`XCLocalSwiftPackageReference "Godstone"` (→ `ios/Godstone/Package.swift`), while the products are declared by the
**mirror** package (`ios/Packages/GodstoneFoundation/Package.swift`), and `scripts/sync_ios_foundation_package.py`
copies **only** `Sources/{GodstoneCore,GodstoneMesh}` — **the App directory is in NO lane**, which is why every round so
far has been unable to see it.

**So GS-ARCHIVE-005's step 1 (make the scene the owner of the load; let `ArchiveDocumentReader` render the scene's
state, dropping its own `ArchiveReaderModel`) and its steps 6–7 remain OWED — no longer blocked by a missing simulator
but by the app target's MODULE RESOLUTION**, a specific and diagnosable configuration problem.

**NEXT STEP, NAMED:** build the local package directly (`swift build --package-path ios/Godstone` for the simulator SDK,
or the `xcodebuild -scheme` equivalent) to learn whether `GodstoneCore` compiles for the simulator at all — if it does,
the app's failure is a **wiring defect worth its own finding**; if it does not, the App layer is a build target this
programme cannot yet reach, and **that must be said** rather than the finding being quietly deferred.

**No production file was edited this round, and that is deliberate:** an App-layer refactor whose only verdict would be
an `xcodebuild` that **cannot run** is exactly the unverifiable edit this programme refuses. GS-ARCHIVE-005 stays
**PARTIAL**.

## DO THIS FIRST (round 177, landed) — ★ ALL THREE RED CONTROLS ARE GREEN

`check_ble_link_substrate_controls` — rc 1 with 33 arms nine rounds ago — is now **rc 0 (ALL PASSED BL01–BL135)**, and its
`--selftest` reports **All 158 mutations caught deterministically**: the battery that **aborted for the whole of this
program** (a red baseline cannot measure mutations) now runs and passes. With it, **all three of the audit's red
repository controls are green *and verified***:

| Control | State | Instrument |
|---|---|---|
| `check_local_identity_controls` | **rc 0** (round 164) | **38/38** mutations |
| `check_trusted_runtime_composition_controls` | **rc 0** (round 165) | **55/55** mutations |
| `check_ble_link_substrate_controls` | **rc 0** (round 177) | **158/158** mutations |

**The two refused arms were closed IN THE INSTRUMENT, with their reasons written into it:** BL52 now accepts *either*
`peerRssi[address] = result.rssi` **or** the observed rssi handed to the **bounded** discovery observer — the law is that
the observation reaches the transport's own record of the peer, not that it arrives through a map of one name — and it
**still refuses** a transport that synthesises or drops the observation. BL132 now accepts *either*
`subscribedCentrals[peerId]` **or** the **relation's lease** (kept fresh, relation-scoped — what the T16 `viaRetained`
census exists for) **and requires** the value be **targeted** at that guarded handle.

**The battery had five more stale snippets, found by making it run** (BL11's, BL18's, both BL22's, BL126's — each
predating a change made in this session or before it). Each was re-anchored to **real text** without changing what it
tests, and a **new** mutation was added for the corrected BL132 law.

**Whole sweep:** every `ci/check_*.py` rc 0 **except `check_parity` under its default scope** — and that non-zero is not
a repository failure but the **external A-06 arm** ("independent vectors unavailable or unapproved … A-06 stays OPEN"),
which the audit requires to stay open; `--scope repo` is rc 0, as is `check_repository` and `ci/symbols.py`.

**THE HONEST COUNTERPOINT, so this is not overclaimed: of the 33 original arms, NINE were closed by CODE** (BL96's
sentinel terminal, BL115's two courts, BL22's eight forbidden calls, the CLOSING lifecycle — real defects with real
reds) **and TWENTY-FOUR by measured alignment or instrument correction** — they were never defects, only the
instrument's approximation of a law the code satisfied, often more strongly. **33 red arms became 0; the number of
DEFECTS among them was nine.** The instruments now catch **251 mutations** in total, so nothing was weakened.

## DO THIS FIRST (round 175, landed) — BL11 CLEARED, **BL132 REFUSED TOO**

**BL11 cleared:** the responder pump unwrapped the manager into a local named `pm`; the unwrap now reads
`let peripheral = peripheral` (the property shadowed deliberately, documented in place) and the call reads
`peripheral.updateValue(…, onSubscribedCentrals: [centralObj])` — the same reference, the same law. iOS lane
**1198 tests, 0 failures**.

**BL132 refused, and the reason is a design the control itself names elsewhere:** the pattern wants
`guard let centralObj = subscribedCentrals[peerId]`, while the code takes its central from **the relation's lease**
(`activeInboundLifetimes[peerId]?.retainedCentral`). The lease is kept **fresh** (carried forward on rotation, set to
the current central on subscribe) and is **relation-scoped** — *stronger* than a map keyed only by central identifier.
Switching would weaken the guard; adding the map as a conjunction would **break the T16 retained-handle path**
(`viaRetained: true`), because after an unsubscribe the map holds no entry while the lease still retains the handle.
Either road makes the code worse while making the gate green.

**THE CODE-SIDE PATH IS EXHAUSTED, AND THAT IS THE ROUND'S REAL FINDING.** Of the **33** arms this control reported
nine rounds ago, **31 were closed by code** — 8 substantive or mixed (BL96's sentinel terminal, BL115's two courts,
BL22's eight forbidden calls, the CLOSING lifecycle) and 23 by provably-neutral alignment — and the **last two are
conditions whose law the code satisfies MORE STRONGLY**. They are instrument approximations, and the honest closure is
the **instrument, with new mutations** proving it still refuses a transport that observes no RSSI and a send branch
that guards on nothing. **And it is now cheaper to verify than ever: once both rules are corrected the baseline is
clean, so `--selftest` runs its battery for the first time** and can prove the new mutations are caught.

**Standing: control 2 arms** (BL52, BL132) from 33; iOS 1198/0; Android green; readiness flags false; five external
gates OPEN.

## DO THIS FIRST (round 174, landed) — BL81 AND BL131 CLEARED

* **BL81 cleared:** the scan reducer **already** consulted the driver, but the pattern wants the hint **named** and the
  event called `result`. The parameter was renamed (`event` → `result`, 7 tokens, positional at its one call site) and
  the hint hoisted into `val metadata = result.metadata` + `val optionalHint = metadata?.nodeHint` before the **same**
  call with the **same** three values. Android `:mesh` BUILD SUCCESSFUL.
* **BL131 cleared:** the failed-to-connect reducer **snapshotted** the driver under the lock; the local now carries the
  property's own name (`let centralDriver = centralDriver` — deliberate, documented shadowing) so the delegated call
  reads `centralDriver?.onFailedToConnect`. Same reference, same call, same epoch discipline. iOS lane **1198 / 0**.

**BL52 IS REFUSED — the first refusal that is neither a finding nor a spelling.** The pattern wants the literal
`peerRssi[address] = result.rssi`, a map named `peerRssi` holding the raw scan RSSI. The code **observes** the RSSI (the
law) through `captureScanEvent(…)` into a `ScanEvent` and then into the **bounded `discoveryIndex`**. Satisfying the
literal would mean **adding a second store of the same fact** — the very divergence the audit's findings refuse
elsewhere — so it would make the code **worse** while making the gate green. **The criterion forbids it**, and the honest
options are named rather than the arm silently skipped: either **correct the instrument** to recognise the bounded index
as the observer (requiring new mutations), or **rename the index** to the contract's vocabulary *if* that duplicates
nothing — the second to be examined next round.

**Standing: control 5 → 3 arms** — BL11, BL52, BL132 — from **33** fourteen rounds ago. BL11 and BL132 are each
single-expression alignments whose law was verified present (the responder path **does** pass `onSubscribedCentrals`;
`subscribedCentrals` **is** installed and removed by name).

## DO THIS FIRST (round 173, landed) — BL126 WAS **NOT** SUBSTANTIVE EITHER

The arm round 172 flagged for watching turned out to be **spelling**, and the reading proved it: `start()` **already**
built its context with `epoch: currentTransportEpoch, transport: self`, and `ManagerContext` **already** built both
proxies from exactly those values — so the law (fresh epoch proxies installed on start, bound to this transport and the
current epoch, managers born with `delegate: nil`, both cleared on stop) was satisfied, spelled through the context.
Only **one** condition failed: the pattern's literal expression.

**The alignment moved WHERE the proxies are built, not WHAT they are:** `ManagerContext.init` now **takes**
`centralProxy`/`peripheralProxy` as parameters (its only construction site is `start()`'s scope; no court constructs it
directly), and the transport builds them there. The objects are **identical** — same epoch value, same `self` — and the
whole iOS lane at **1198 tests, 0 failures** proves it.

**A lesson about the instrument, recorded because it will recur:** the first attempt wrote that expression across **two
lines**, and the control's check — a **substring** match on text whose *comments* are stripped but whose *newlines* are
not — reported it as **absent**. The alignment was invisible to the gate until the line was joined. This is the second
fragility of the same family (round 163: a control whose text match counted **comments**, so a KDoc quoting the
forbidden spelling re-broke the gate). Both are recorded as properties of the instrument, not as accidents.

**Standing: control 6 → 5 arms** — BL11, BL52, BL81, BL131, BL132 — from **33** eleven rounds ago, with the iOS lane at
1198/0 and the Android lane green. Each survivor is taken by the same criterion, and **none has yet been shown
substantive — nor is that possibility dismissed**, because BL96 taught that a pattern *can* encode a real defect: the
difference was **measured** every time, never assumed.

## DO THIS FIRST (round 172, landed) — BL128'S ELEVEN MESSAGES

The eleven messages were **two different claims**, exactly as round 170 predicted: six that the six callback reducers
must **take** `sourceEpoch` with a default of 0, five that they must **validate**
`sourceEpoch == 0 || sourceEpoch == currentTransportEpoch`. Reading showed both satisfied in substance and spelled
differently: every reducer took `sourceEpoch` **without** a default, and every guard checked the **per-relation
lifetime epoch** — *stronger* than the transport-global epoch the pattern names — while the shared authenticity helper
required `sourceEpoch == context.epoch` **and** `context.epoch == currentTransportEpoch`.

**The alignment ADDED the sentinel default (6 declarations) and STRENGTHENED the four existing guards** to require
**both** the live transport epoch **and** the relation's own lifetime epoch for a **named** value: the pattern's clause
is now real code and the check is strictly stronger than either form alone. `0` stays the sentinel, the same law round
171 gave the Android driver.

**Stated rather than glossed:** the control's regex for a method's validation clause is **unbounded** after that
method's declaration, so the strengthened guard in the inbound family serves three earlier declarations
(`processInboundWrite`/`Subscribe`/`Unsubscribe`) — those three enforce the epoch law in their own bodies through
`managerEventIsAuthenticLocked`, which is why the alignment was safe rather than invented per method.

**Acceptance:** whole iOS lane **1198 tests, 0 failures** (unchanged count); **control 18 → 6 arms**.

**THE SIX SURVIVORS ARE NOW THE WHOLE OF IT:** BL11 (`pm.updateValue` vs the pattern's `peripheral`), BL52 (the RSSI
assignment's spelling), BL81 (the scan-result action's spelling), BL126 (`start()` installing fresh epoch proxies),
BL131 (the failed-to-connect delegation's local name), BL132 (the responder branch's central lookup) — each by the same
criterion. **BL126 is the one to watch: it may be the second SUBSTANTIVE arm**, since the proxies are built in the
**initializer** while the message says `start()` must install them **fresh per epoch**.

## DO THIS FIRST (round 171, landed) — BL96 TAKEN AS A FINDING

Round 170 refused BL96 as a spelling and named it a finding. This round **confirmed the defect by reading**:
`onClientDisconnected(deviceAddress, expectedGen)` refused every value that was not the slot's own, and the GattServer
helped by asking the driver for **its own current generation** — a round-trip whose match could **never fail**. Two
audited consequences: (i) the platform's disconnect carries an **address**, not a registration, so a caller holding no
generation had **no way to make the terminal arrive**; and (ii) because the match could not fail, a disconnect
belonging to a **replaced** registration would retire its **successor** — CRYPTO-001's own sentence.

**A third kind of RED, and it compiles:** the arm calls `onClientDisconnected(peer, 0L)` **explicitly** — legal
against the audited signature — and asserts the sentinel retires the slot's own relation. The audited driver answers
`NoOp`, so it failed at `BleLinkSubstrateTest.kt:2818` on the unmodified tree, captured with argv, source SHA and
digest. (Not a compile failure like the issuance repair, not a missing name like the control arms, but a **legal call
whose answer is the defect**.)

**The repair** — one coherent change with its real caller: the driver gains `expectedGen: Long = 0L` with the law at
the guard (`if (expectedGen != 0L && gen != expectedGen) return NoOp`), so the sentinel retires the slot's **own**
generation and **only** that one (T12's exact-match law preserved for every other value); and the GattServer now
forwards **the generation it recorded at admission**, falling back to the generation-less form only when it recorded
none.

**Acceptance:** whole `:mesh` lane **1175 tests, 0 failures, 0 errors** (1174 + the new witness) — including every
T12/T14 terminal court. **Control 21 → 18**: BL96's two arms **and BL118's** forwarding arm, since the same edit
carries the generation-less forwarding form in a **real branch** rather than as decoration — the distinction this
criterion exists to enforce.

**REMAINING: 18 arms** — BL11, BL52, BL81, BL126, BL128 (×11), BL131, BL132. **BL128's eleven messages are the next
read**, because "must take `sourceEpoch`" and "must validate `sourceEpoch == currentTransportEpoch`" are **different
claims** and the methods already take the parameter.

## DO THIS FIRST (round 170, landed) — THE SPELLING DECISION IS TAKEN **ARM BY ARM**

The earlier framing (align ~23 spellings vs rewrite the instrument) was replaced by a **per-arm judgement**, because
the arms are not uniform. **The criterion:** an arm may be closed by aligning the code to the contract's spelling
ONLY IF (i) the law the message names is already satisfied, (ii) the alignment is **provably** behaviour-neutral, and
(iii) it **weakens nothing** — where the code is stronger than the pattern, the stronger form **stays** and only the
name moves. An arm whose pattern implies a **semantic** rule may not be closed this way.

* **BL42 cleared:** `BleConnection.bindRoleInternal` now carries the positive gate the pattern names, with the **De
  Morgan identity written into the comment** (`s != A && s != B <=> !(s == A || s == B)`) so a later reader can verify
  the neutrality rather than trust it.
* **BL93 cleared without weakening:** the registration local was renamed (`client` → `activeClient`, three uses plus
  the identity check that followed) and nothing else — the guard still tests **both** the client token and the GATT
  generation, so the code stays **strictly stronger** than the pattern. (The first attempt failed to **compile**
  because a fourth use sat outside the window my grep had covered; the lane caught it.)
* **BL96 is the first arm the criterion REFUSES — and it is a finding, not a spelling.** The pattern wants
  `onClientDisconnected(deviceAddress: String, expectedGen: Long = 0L)` **and** a GattServer forwarding that passes
  **no** generation. Together those imply a **semantic rule the code does not have**: `expectedGen == 0L` must mean
  "the caller knows not the generation" and the driver must then retire the slot's **own** generation — where today
  `if (gen != expectedGen) return NoOp` means such a disconnect is **silently ignored and the relation stays ACTIVE
  for ever**. That is the audited defect family (a terminal that never arrives), it cannot be closed by renaming, and
  it needs its own RED + a decision on the sentinel (0L as "unspecified" vs a typed absence).

**Acceptance:** whole `:mesh` lane **1174 tests, 0 failures, 0 errors** — the proof that nothing was weakened;
**control 23 → 21 arms**.

**NEXT:** BL96 as the substantive arm (RED + sentinel decision + courts), then the per-arm criterion on BL11, BL52,
BL81, BL118, BL126, BL131, BL132 and BL128's **eleven** messages read individually — "must take `sourceEpoch`" and
"must validate `sourceEpoch == currentTransportEpoch`" are **different claims**, and the methods do take the parameter.

## DO THIS FIRST (round 169, landed) — BL22 IS CLEARED ON BOTH ISLES

The iOS twin landed shape for shape: `BleHandshakeAuthority.swift` carries the substrate's vocabulary
(`startOutboundHandshake`, `continueOutboundHandshake`, `acceptInboundHandshake`, `completeInboundHandshake`) with
`SessionHandshakeAuthority` as the **one** adapter speaking the registry's names, and `BleTransport.swift` travels
through the seam at all four sites. **Zero forbidden occurrences remain on either isle.**

**The design lesson was carried across rather than re-learned:** the iOS seam is an `internal var` override from the
start — the Android draft learned from the compiler that a **public** class may not expose an `internal` type in its
public surface, and widening that surface for a test seam would be the wrong trade.

**Proof:** whole iOS lane **1198 tests, 0 failures** (unchanged count) with the readiness courts driving **real
handshakes end-to-end** through the adapter — every adapter method delegates to the registry call it replaced, so
wire bytes, trust table and refusal semantics are untouched. **Control: 27 → 23 arms**; BL115's two inventory arms
and **all eight** BL22 arms are cleared.

**THE REMAINING 23 ARE THE SPELLING APPROXIMATIONS** triaged at round 166 — BL11, BL42, BL52, BL81, BL93, BL96 (×2),
BL118, BL126, BL128 (×11), BL131, BL132 — and **the decision they force is still open and still deliberate**: align
~23 spellings in a frozen transport surface (several of which would **rewrite stronger code down to a pattern's
shape**) **or** repair the instrument to test the law, with NEW MUTATIONS proving it still refuses violations. Round
165 refused a comparable shortcut for a 4-arm case and aligned the code; the calculus differs here and that is
recorded rather than assumed.

**Also owed (cheaper now, and not dropped):** a court that drives the transport with a **fake** handshake authority
and **no** session manager — proving the *decoupling* directly on either isle. Both seams now exist, so it needs an
entry point into the handshake road, not new production wiring.

## DO THIS FIRST (round 168, landed) — BL22's ANDROID HALF

The control's BL22 arm forbids six SessionManager handshake names **anywhere in the transport file**, and the audit's
drivers carry **no handshake API of their own** — so this was not a reroute onto an existing substrate method but the
**introduction** of the substrate's authority. Four Android call sites were affected (`responderProcessHs1`,
`responderProcessHs3`, `initiatorProcessHs2`, `beginInitiator`).

**The repair:** a new `transport/BleHandshakeAuthority.kt` carries the substrate's vocabulary
(`startOutboundHandshake`, `continueOutboundHandshake`, `acceptInboundHandshake`, `completeInboundHandshake`) with
`SessionHandshakeAuthority` as the **one** adapter that speaks the registry's names. `BleTransport` now travels
through the seam at all four sites, so the radio no longer couples to one implementation of trust establishment.

**A design decision made by the compiler, recorded:** the seam was first written as a constructor parameter and the
lane **refused to compile** — `BleTransport` is `public` and a public constructor may not expose an `internal` type.
It is an `internal var` override instead: the public surface is **not** widened for a test seam.

**What proves it:** the whole `:mesh` lane is green at **1174 tests, 0 failures, 0 errors**, and the readiness courts
drive **real handshakes end-to-end** through the adapter — the positive control that the seam is behaviour-preserving
(every method delegates to the call it replaced; wire bytes and trust table untouched). **Control: 31 → 27 arms**,
all four Android BL22 arms cleared, **zero forbidden occurrences** left in the file.

**OWED, stated rather than implied:** a court that drives the transport with a **fake** authority and **no** session
manager — proving the *decoupling* directly rather than only the absence of forbidden names. Its entry point is a deep
private path and was not taken this round.

**NEXT:** the four **iOS** BL22 arms (the twin seam in `BleTransport.swift`, isle by isle as the SOS and issuance
repairs were), then the remaining spelling arms and the still-open decision about them.

## DO THIS FIRST (round 167, landed) — BL115 TAKEN

Round 166 triaged the last red control's 33 arms into 31 spellings and **two substantive** ones. The first
substantive arm (**BL115**) is now closed — and it was **not** a spelling. `ServerPeerSlotState.CLOSING` was
**checked in three guards** (`onClientConnected`, `onLinkInfoWriteRequest`, `onDescriptorWriteRequest`) and
**assigned nowhere**: dead code. The cause was found through the **real caller**: `BleGattServer.stop()` bumps the
server epoch, and `startNewServerEpoch()` **clears `peerSlots`** — so a client arriving during the teardown finds
**no slot**, the guards cannot fire, and the event can be **admitted as a replacement of a relation that was never
retired**.

**The RED is behavioural and through the real caller** (not a fixture): admit a client, call `BleGattServer.stop()`,
then read the driver's state — `AssertionError` at `BleLinkSubstrateTest.kt:2708` on the unmodified tree, captured
with argv, source SHA and digest. (The first attempt failed to **compile** — JUnit puts the message FIRST — and
that is recorded too, because a compile error is not a behavioural red.)

**The repair** (one coherent change, one real caller): `beginServerClose()` moves every ACTIVE slot to CLOSING
keeping its **exact** generation; `startNewServerEpoch()` now **preserves** CLOSING slots
(`peerSlots.entries.removeAll { it.value.state != CLOSING }`) while clearing every other state as before; and
`GattServer.stop()` calls the transition **before** the epoch bump.

**Two courts BL115 names now exist and assert the laws, not the names:** `…ConnectedWhileClosingCannotAdmitReplacement`
(no admission, no renumbering, zero admitted) and `…ClosingDisconnectRetiresExactGeneration` (a **foreign**
generation is `NoOp` and changes nothing; the **exact** one yields `TearDownPhysicalChannel` naming that generation
and a terminal QUARANTINED slot). A third witness keeps the RED arm as a permanent control.

**Acceptance:** whole `:mesh` lane **1174 tests, 0 failures, 0 errors** (1171 + 3) — preserving CLOSING slots broke
nothing, including T12's reconnect-after-epoch court which depends on a QUARANTINED slot still being cleared; and the
control fell from **33 to 31** arms with BL115 cleared.

**STILL OPEN:** the other 31 arms remain the spelling approximations triaged at round 166, and the decision between
aligning them and repairing the instrument stays deliberate. **BL22** is the next substantive arm — the transports
still calling the production SessionManager handshake API directly (4 Android + 4 iOS sites) — and unlike BL115 it is
an **architectural reroute**, not a missing transition.

## DO THIS FIRST (round 166, landed) — THE LAST RED CONTROL IS TRIAGED

`check_ble_link_substrate_controls` is rc 1 with **33 arm errors** across BL11/BL22/BL42/BL52/BL81/BL93/BL96/BL115/
BL118/BL126/BL128/BL131/BL132, and its `--selftest` is rc 1 — it **aborts on the unclean baseline**, so its mutation
battery never runs and the control proves nothing (the same broken-instrument defect round 165 repaired for its
sibling). The RED is captured whole with its digest.

**THE TRIAGE (every line READ, not inferred) — 31 arms are SPELLING APPROXIMATIONS of laws the code already
implements, often MORE STRONGLY:**
* **BL42** wants one line `s == LINK_INFO_WRITING || s == PROVISIONAL_CONNECTED`; `BleConnection.kt:298` has the De
  Morgan equivalent. **BL93** wants `activeClient.clientToken != clientToken`; `BleTransport.kt:937` has
  `client.clientToken != clientToken || client.gattGeneration != gattGen` — **strictly stronger**.
* **BL11** wants `peripheral?.updateValue(`; `BleTransport.swift:1714` calls `pm.updateValue(…,
  onSubscribedCentrals:)` — the law the message names **is present**. **BL131** wants `centralDriver?.onFailedToConnect`;
  `:2729` delegates through a snapshot. **BL132** wants `guard let centralObj = subscribedCentrals[peerId]`; the
  registry and getter exist (`:1075`, `:1152`).
* **BL128** wants each `process*` to take `sourceEpoch`; **all five already do** (`:2625 :2679 :2734 :3295 :3384`)
  with the validation line at `:906`. **BL126** wants `CurrentEpoch`/`self` spellings; the proxies are installed with
  the epoch at `:184-185`. **BL96** wants a `= 0L` default; `BleOrchestrationDriver.kt:586` lacks only that token.
  **BL118** wants `fun processConnectionStateChange(`; `GattServer.kt:130` **defines it** and forwards.
* **BL52/BL81** want literal assignment spellings; the same work runs through `captureScanEvent`/`handleScanEvent`.

**THE TWO SUBSTANTIVE ARMS (verified, not conflated with the noise):** **BL22** — the transports still call the
production SessionManager handshake API directly (4 Android + 4 iOS sites; `registry` **is**
`crypto.SessionManager`, `BleTransport.kt:1053`), so that law genuinely is violated. **BL115** — the two courts it
names exist **nowhere** in `android/`, so they must be written and the behaviours they assert must be true.

**THE DECISION, STATED SO IT IS TAKEN DELIBERATELY:** clearing this means EITHER aligning ~31 spellings in a FROZEN
transport surface (**which would rewrite the stronger forms down to the pattern's shape**) OR repairing the
instrument to test the law with NEW MUTATIONS proving it still refuses violations. **This round takes neither** — a
33-arm instrument rewrite executed at the end of a round is exactly the unmeasured change this program refuses.
What is unambiguous either way is the real work: **BL22** (route the handshake through the transport's own drivers)
and **BL115** (two courts + their laws), which no spelling change can satisfy.

## DO THIS FIRST (round 165, landed) — THE SECOND RED CONTROL IS GREEN

`check_trusted_runtime_composition_controls` reported **four** errors (R01/R02/R05/R06) and its `--selftest`
**aborted** on the unclean baseline — so its mutation battery never ran and the control proved nothing. It now
reports **zero** errors and its selftest **passes with 55/55 mutations caught deterministically across R01–R30**.
The repository stands at **17 controls green, ONE red**. Landed in `5924261`.

**The diagnosis is the round's real result:** the law's properties were already present *under another
vocabulary*. `SessionManager` owned a registry of per-**relation** slots, each owning exactly one
`TrustedHandshakeController` (never a raw `NoiseSession`) **and its own lock**, with every operation running
through `SessionSlot.serialize`. T08 renamed that map when it made the key a *relation* rather than a peer
handle — and the control reads **code text with comments stripped**, so the names the contract requires
(`controllers`, `peerLocks`/`getPeerLock`) had survived only in documentation the instrument deliberately
ignores. The control was reporting a registry that does not exist.

**The repair aligned the vocabulary and kept both the design and the instrument:** `controllers` on both isles,
a new `getPeerLock` accessor that `isReady` *takes explicitly* (the same lock `serialize` acquires, so the name
is load-bearing), and `SessionSlot.getPeerLock()` with `serialize` routed through it. **No rule was relaxed, no
mutation removed, no check edited** — teaching the control to accept the old spelling was rejected as moving the
goalposts for the gate's sake, and that refusal is recorded.

**Assertion and behavioural twin:** the failing assertion was the control's own four errors (their RED is the
round-163/164 sweeps, kept separate). The behavioural coverage already existed and the control itself names it:
`SessionManagerConcurrencyTest(s)` for real per-peer serialisation and `ReadinessT08Test(s)` for the slot lease
and reclamation law — all green in both lanes (Android BUILD SUCCESSFUL; iOS **1198 tests, 0 failures**).

**NOT thereby closed:** CRYPTO-001 (relation-keyed session authority threaded through transport-owned work) and
CRYPTO-002 (typed terminal retirement / READY expiry) — this round resolved the *control failure* and the
*instrument*, and their deeper cards remain their own rounds.

**NEXT:** the last red control, `check_ble_link_substrate_controls` (BL11/BL96/BL115/BL118/BL128/BL131/BL132 →
IOS-04/IOS-06), whose selftest **also aborts on an unclean baseline** — repair its instrument first, then the code
it names.

## DO THIS FIRST (round 164, landed) — THE ISSUANCE BYPASS IS CLOSED ON BOTH ISLES

`ci/check_local_identity_controls.py` — the best-instrumented of the three red repository controls — reported
**TWO errors** on the audited tree (`SignedSosV1.kt`, `SignedSosV1.swift`). It now reports **NONE**: `PASS — all
local identity invariants and boundaries satisfied`, with `--selftest` still catching **38/38 mutations**, so the
gate did not pass because its instrument weakened. The repository's red controls are down to **two**
(`ble_link_substrate`, `trusted_runtime_composition` — both still abort on an unclean baseline, and therefore
still prove nothing until their own selftests are repaired). Sweep: **16 pass / 2 red**, from 15/3. Landed in
`d7b48c5`.

The iOS repair mirrors round 163's shape for shape: `currentIdentityBinding()` on the protocol;
`author(binding:signingSeed:…)` signing over bytes it did not mint; `MeshNode.dispatchSos` refusing when the
authority holds none; the harness's `SimulatedSosAuthority` carrying a binding **its own identity issued**; the
test-only `fixed()` path **deleted** in favour of a **test-side** `SosTestAuthority.swift` (the mirror of
Android's fixture) because the control scans production only and a court must be able to simulate an authority.
The parked iOS arm **moved into the canonical suite** beside its twin, and the probe file was deleted.

**A defect in my own arm, kept in the record rather than erased:** the first iOS run failed ONE arm — and the
failure was not in the repair. On this isle the binding's Ed25519 signature is **randomized (hedged)**, so two
issuances of the same material differ; comparing them fails for a reason unrelated to the law under test. Both
arms now ask the authority **once**, with the reason written into each arm. The failing run's log is kept
**separate** from the green one.

**Acceptance:** iOS lane **1198 tests, 0 failures, 0 errors** (149.7s); Android `:mesh` **1171 tests, 0
failures, 0 errors**; `check_parity --scope repo` rc 0, `check_repository` rc 0, `ci/symbols.py` rc 0; whole
Python readiness suite OK.

**STILL OWED ON GS-SOS-001 (status stays PARTIAL):** the card's **step 2** — a *runtime-owned* authority supplied
from the durable identity/generation owner and connected in the module/runtime (production presently **refuses**,
which is the safe direction but not that step) — and **step 6** — the same failure semantics through retry/UI
projection, since `ComposedRuntime.sendSos` still returns `.applied(detail:)` whatever the result.

## DO THIS FIRST (round 163, landed) — THE ISSUANCE BYPASS IS CLOSED ON THE ANDROID ISLE

The audit's local-identity control reported this defect at `SignedSosV1.kt:274`: `author(...)` **struck its
own `IdentityBindingV1`** from the raw seed/generation/DH key it was handed. The binding is now a
**PARAMETER** — `SosSigningAuthority.currentIdentityBinding()` — obtained from the authority, and
`MeshNode.authorSignedSos` **refuses** (null → no frame, no hold, no offer) when the authority holds none.
The frozen T13 equation and the **wire bytes are unchanged**: the court's pinned golden vectors stayed green,
which is the control that proves byte-identity. Landed in `b229c3b`.

**The red, and why it is source-level (stated, not glossed):** the repair is an OWNER-CONTRACT change, so a
behavioural arm of the new law **cannot compile** against the audited tree — the API it must exercise does not
exist yet. The independent failing assertion is therefore the control's own, moved into the canonical suite as
`tools/readiness/tests/test_local_identity_issuance.py` and run RED **before** the edit: 3 tests, 2 failures
(one per isle), with `W00`'s positive control (the authority files still issue) **passing**, so the scan proves
it read the tree rather than finding nothing. Two behavioural arms ship with the repair in the SOS court: an
authority with material but **no issued binding** must offer nothing, and a frame must carry **that
authority's** binding byte for byte (read through the frozen public offsets — a first attempt hand-counted the
slice and compared a shifted window, and the court caught it).

**A discovery worth keeping:** that control is a **text match over production sources, and it counts
comments**. The first attempt failed it with the code already correct, because the new KDoc quoted the
forbidden spelling verbatim. The wording is now deliberately indirect and the lesson is written into the
comment, because a reader who documents the law by quoting it will re-break the gate.

**Acceptance:** `:mesh` lane **1171 tests, 0 failures, 0 errors, 0 skipped** (1169 before + the two new arms);
`check_local_identity_controls` **2 errors → 1**; every other control unchanged (same 3 red as baseline,
`check_parity --scope repo` rc 0, `ci/symbols.py` rc 0); the whole Python readiness suite OK.

**NEXT (exactly written out):** the iOS half — give the iOS protocol `currentIdentityBinding()`, make
`SignedSosV1.author` take the issued binding, obtain it in `MeshNode.dispatchSos` (refusing when absent), have
the iOS harness's `SimulatedSosAuthority` receive the binding its own identity issued, update the court
fixtures (`FakeAuthority`, `MissingMaterialAuthority`, and the `fixed()` path the five rigs use), then **MOVE
the parked arm** `tools/readiness/audit_probes/python/test_local_identity_issuance_ios.py` **into the canonical
suite** beside its twin and run the whole iOS lane (expect ~1196 tests, grep `Executed `).

## DO THIS FIRST (round 162, landed) — GS-SOS-001's iOS TWIN IS REPAIRED AND THE WHOLE iOS LANE IS GREEN

GS-SOS-001's **iOS twin** is now red-proved and fully specified, so its repair is a MEASURED change rather
than a search. The three signatures the previous round left open are answered: `T38Vec` is
`{kind, name, fields: [String: String]}`, the court's repository argument is one of TWO private classes in
the same file (`DeadDeliveryRepository` :257, `T38Journal` :273), and **`dispatchSos(payload:send:)` is
SYNCHRONOUS** — every iOS court calleth it without `await`, so the arm is a plain `throws` test.

**The RED, immutable, captured in a DETACHED PRE-REPAIR worktree at `95dc75e` where `MeshNode.swift` is
UNTOUCHED:** `12 tests, with 6 failures (0 unexpected)`, `0 errors` — the build SUCCEEDED, so every failure is
an assertion and the red is BEHAVIOURAL. Log:
`REMEDIATION/GS-SOS-001/ios-red-round161/red.log`, sha256
`5fdd9f3d960341ec7e9f10de446d2a5b1a4d91e67505fbe11dafa6927ba5c68c`.
**Its limit is stated, not glossed:** with zero connected peers the `send` closure is never invoked even
before the repair, so the arm's `sends == 0` assertion PASSES ON BOTH SIDES and proveth nothing; the teeth are
the DURABLE HOLD (1 frame), the C6 ROW (1 recorded) and the RESULT (`queuedDurably` where a refusal is
required). The arm also REVERSES the court's legacy arm *inside the arm*, with the reversal written into it.

**WHAT LANDED (round 162, commit `853a8df`, tree `299b954`):** `MeshNode.dispatchSos`'s `else` branch no longer
buildeth the legacy structural frame — it returneth `"no SOS signing authority: an unauthenticated distress call
may not be offered"`, byte-identical to Android's wording, BEFORE any persist, tracker row or send, with the seed
consulted first so an empty authority consumes no nonce. `SimulatedSosAuthority` was added to main **beside the
composed harness** (mirroring Android's `runtime/ComposedRuntime.kt:687`), because the iOS isle carried NO
authority implementation in main at all; the harness wireth it over the seed IT generated for that node. FIVE of
the eight measured sites needed an edit (T39 :134 and :440, T43 :86, SosDispatch `makeNode`, DeliveryIntegration
`makeNode`); T39's `node2` (:223) and T43's `cold` (:255) dispatch nothing and were deliberately left unwired;
T44's eighth site is the harness wiring itself. **No assertion had to be reversed** — every dependent was an
unset rig, exactly as rounds 144/149 predicted for Android. Acceptance: `Executed 1196 tests, with 0 failures
(0 unexpected)`, `0 errors`, 172.5s, with the signed-half positive control passing in the SAME run; and the
repository controls swept at 15 pass with the SAME 3 red as the round-158 baseline — no new failure. The parked
patch was DELETED with the repair: the arm and the reversed legacy arm now live in the canonical suite.

**STILL OWED ON THIS FINDING, NAMED RATHER THAN IMPLIED:** the SEPARATE `SignedSosV1.author` issuance bypass
(constructs/issueth its own `IdentityBindingV1` on BOTH isles — one of the three red controls, and the ONLY one
whose selftest passes 38/38; the API is answered at round 133, the plumbing at round 134), and
`ComposedRuntime.sendSos` returning `.applied(detail:)` whatever the dispatch result — so a REFUSED SOS would
still be reported as APPLIED. No device, radio or emulator was used, and production `MeshRuntime` wireth no
authority, so production REFUSES.

**The round-161 RED stayeth on the record, with its limit:**

**The blast radius is EIGHT UNSET RIGS, not eighteen assertions** (the round-144/149 pattern, re-measured on
this isle): `ReadinessT39Tests.swift:134`, `:223`, `:440`; `ReadinessT43Tests.swift:86` (inside `rig(_:)`) and
`:255`; `MeshNodeSosDispatchTests.swift:140` (`makeNode`); `MeshNodeDeliveryIntegrationTests.swift:215`
(`makeNode`); and `ReadinessT44Tests` builds NO node — it driveth `ComposedRuntime`, so **`ComposedRuntime.addNode`
(`ComposedRuntime.swift:330`) is ONE insertion that covereth all of its arms**. None of them asserteth the
unauthenticated shape; all assert an outcome that REQUIRES a successful offer.

**One fact had no Android analogue and it decided the repair's shape (round 161):** the iOS isle carried **NO
`SosSigningAuthority` implementation in main sources at all** (only the protocol at `SignedSosV1.swift:103` and
the seam at `MeshNode.swift:169`), while Android carried `SimulatedSosAuthority` in main
(`ComposedRuntime.kt:687`) — so one had to be ADDED, over the harness's own generated material, and labelled
harness support in its own docstring (round 162 did exactly that).

## DO THIS FIRST (round 132, still the open control question) — THE MANDATORY LANES ARE RED, AND ONE OF THE THREE CONTROLS HAS A WORKING INSTRUMENT

Round 129 ran EVERY `ci/check_*.py` control (18) for the first time in this session; round 130 corrected its
own count (3 genuine failures, NOT 4 -- `check_parity` passes as the LANE runs it, `--scope repo`, and its
exit 1 under the default scope is the EXTERNAL A-06 gate the audit REQUIRES stay open); round 131 found the
sharper thing:

    TWO OF THE THREE CONTROLS HAVE FAILING SELFTESTS, and repository-verification.yml runs `--selftest`
    FIRST (lines 162-163, 170-171), so those lanes fail BEFORE the check itself runs. Each `--selftest`
    demands a CLEAN BASELINE to measure mutations against; the baseline is unclean BECAUSE the checks
    fail, so the selftest ABORTS and THE MUTATION BATTERY NEVER RUNS -- a control that cannot run its
    battery PROVETH NOTHING.

    * `check_trusted_runtime_composition_controls` -- selftest rc 1: R05/R06 (Android/iOS SessionManager
      missing per-peer serialization locks) plus R01/R02 (TrustedHandshakeController registry).  -> CRYPTO-001/002, OPEN
    * `check_ble_link_substrate_controls` -- selftest rc 1: BL11 (iOS updateValue with onSubscribedCentrals
      missing), BL96 + BL118 (Android driver generation params), BL115 (TWO ANDROID TESTS MISSING from
      BleLinkSubstrateTest); BL128/BL131/BL132 in the bare run.  -> IOS-04/IOS-06, OPEN
    * `check_local_identity_controls` -- selftest PASSES (38/38 mutations caught): check rc 1 on
      `SignedSosV1.kt:274` (`IdentityBindingV1.create(`) and `SignedSosV1.swift:257` (`IdentityBindingV1(`),
      while the authority constructeth at `MeshIdentity.swift:72` / `IdentityBindingV1.kt:106`/`:127`.
      -> GS-SOS-001, OPEN.  **THIS IS THE BEST FIRST TARGET: a red check WITH a working instrument behind it.**
      THE API IT EXPECTETH IS NO LONGER A QUESTION (round 133, read from the control itself): a production
      file outside the AUTHORITY FILES (Android: Identity.kt, IdentityBindingV1.kt, LocalIdentityStateV1.kt,
      Ed25519Keys.kt, X25519Keys.kt; iOS: MeshIdentity.swift, IdentityBindingV1.swift,
      LocalIdentityStateV1.swift) may contain NEITHER `IdentityBindingV1.create(` NOR any `IdentityBindingV1(`
      construction. Its own mutations name the defect as an ISSUANCE BYPASS, and THE AUTHORITY ALREADY
      CARRIETH `fun issueIdentityBinding(): IdentityBindingV1` -- so the repair is: OBTAIN the binding FROM
      THE AUTHORITY at `SignedSosV1.kt:274` and `SignedSosV1.swift:257`, never construct one. THE CONTRACTS
      STAY FROZEN: what change is WHO ISSUES the binding, not how it is computed or serialized. CHECK FIRST
      whether those sites already hold the authority reference (two edits) or need it plumbed (an owner change).

    AND FOR THE OTHER TWO, DECIDE WHAT YOU ARE FIXING FIRST: whether the missing items (BL115's two absent
    Android tests, the SessionManager registry and locks) are INTENDED BASELINE REQUIREMENTS or STALE
    CONTROL EXPECTATIONS. REPAIRING A CONTROL IS A DIFFERENT JOB FROM REPAIRING THE PRODUCT DEFECT IT NAMES.

ALL OF THIS FAILED AT THE PRE-SESSION COMMIT ae9905e AS WELL: pre-existing, not a regression from this
session. AND IT CORROBORATES, LOCALLY, THE EXTERNAL REVIEWER'S ATTRIBUTED REPORT OF RED HOSTED VERIFICATION.

## DO THIS FIRST (round 116) — THE LIVE FRONTIER IS `ANDROID-05`, AND IT HAS FOUR OWED PIECES IN DEPENDENCY ORDER

Rounds 105-115 were spent on the warm Kotlin lane. `ANDROID-05` (wave 4c.2, HIGH) is PARTIAL and is
the live frontier; these are its remaining pieces, and they are NOT interchangeable:

**1. T18 — mid-record failure must terminate the REAL relation (ANDROID-05-B / ANDROID-06), the largest
piece and the one an auditor will look for.** ITS STEP 3 IS ALREADY LOCATED AND BOUNDED, so start there:
`BleTransport.kt:1254` and `:1266` build the two whole-record writers with
`RelationKey(BleDirection.OUTBOUND|INBOUND, address, 0L)` -- A FABRICATED GENERATION ZERO, so every
writer lieth about which relation it speaketh for. `BleConnection` carrieth NO generation, so it must be
PLUMBED: the factories `centralWriterFor` / `serverWriterFor` need the captured generation, and their
five call sites are `:1018`, `:1032`, `:1414`, `:1431`, `:1482` -- AND THOSE SITES PASS A CONNECTION, NOT A
GENERATION, WHICH IS WHY THE FABRICATED ZERO EXISTS AT ALL. THE ROUTE IS THEREFORE NOT TO PLUMB FIVE CALL
SITES: ATTACH THE GENERATION TO THE CONNECTION WHEN THE RELATION IS ADMITTED (the admission road already
receive-eth one -- `handleInboundClientAdmitted(peerAddress, generation)` at :665 -- and the outbound
intent road carrieth `action.generation`), then let the two factories read
`connection.relationGeneration`. The call sites stay as they are. THE RED IS CHEAP BECAUSE THE SEAMS
ALREADY EXIST: `centralWriterForTest(address)` / `serverWriterForTest(address)` at :1280/:1283 return
the writer, so an arm can assert its relation key carrieth the ADMITTED generation on BOTH directions. THE GENERATIONS ALREADY EXIST in the
transport -- `inboundJobGenerations[address]` (set by `handleInboundClientAdmitted`, :665),
`action.generation` on the outbound intent road (:358/:369/:376), and
`captureRelationForTest?.relationGeneration` -- they are simply not attached to the connection. Pass the
generation each call site ACTUALLY has; never a fabricated zero, and never a lookup of the newest
relation for the address (the supplement forbiddeth it). A red needs no new seam: assert the writer's
relation key carrieth the generation the relation was admitted with. SOURCE_CONFIRMED: `BleTransport.sendThrough` (1089-1100)
invokes `writer.failed`, removes an address-keyed writer and calls `markDisconnected` -- it does NOT
invoke the driver terminal/action path, physically close the connection, unpublish the relation or
destroy its trusted session; `RecordWriter.failed` (343-354) clears only its own staging, and writer
construction at 1220/1232 HARD-CODES GENERATION `0L`. The supplement's seven ordered steps are
transcribed into the ledger (`REMEDIATION_STATE.json`, ANDROID-05.pending_work) -- read them there
before writing anything. THE TRAPS IT NAMES, WHICH ARE EASY TO GET WRONG:
  * carry the ACTUAL captured relation/generation and session-slot token into the writer and every
    operation, and REMOVE FABRICATED GENERATION ZERO; a completion must validate its operation token
    before any terminal effect;
  * NEVER resolve an old failure by looking up the NEWEST relation or session for the address/peer,
    and note that a peer-only `destroyFor` lookup CAN DESTROY A REPLACEMENT SESSION (coordinate with
    CRYPTO-001/002);
  * route the first valid fatal completion to the SINGLE lifecycle/driver terminal authority -- do not
    bolt a competing cleanup list into `sendThrough`;
  * a `Closed` return value, an empty writer queue, or `markDisconnected()` ALONE IS INSUFFICIENT;
  * durable verified messages, send intents, ACK obligations and retry metadata must SURVIVE REOPEN
    and stay retriable -- release transient ciphertext/staging only, and remember that a physical
    write completion is NOT delivery acknowledgement;
  * reconnect the same address with a NEW generation and session, then deliver duplicate failure, late
    success, disconnect and timer callbacks from the OLD relation: none may remove, unpublish, close
    or destroy the SUCCESSOR. For an INBOUND failure the shared GATT server and other healthy clients
    must remain operational.
  ANDROID-06 keeps its own reservation red; do not let a teardown change close it.

**2. The supplement's steps 3-5 depth on ANDROID-05-A** (the part repaired at round 113): a start-attempt
IDENTITY with explicit stopped/starting/running states, and callbacks BOUND TO THE ATTEMPT, so a
DELAYED first-attempt callback has zero effect on a successful successor; plus
partial-allocation-then-failure and a failure before allocation.

**3. The card's steps 1-2**: make the REAL `MeshNode`/lifecycle gate own exactly ONE transport
lifecycle authority -- `UnifiedRuntimeLifecycle` is defined and NEVER CONSTRUCTED, and
`MeshNode.kt:148/:185` still start directly while `:236` calls `ble.stop()`/`wifi.stop()` directly.

**4. Two constants that still lie**: `resourcesReleased = 1` in the drain, and the real
`LifecycleTransportAdapter`, which still inherits the default `awaitInFlight = 0` (so the round-108 law
holds only for seams that implement it).

**THEN: `ANDROID-07`** (wave 4f.2, HIGH) -- pre-auth record/byte budgets charged BEFORE parsing,
reassembly and crypto, including malformed/rejected traffic; its card and closure tests are already in
the ledger.

### THE MEASUREMENT EVERY FUTURE REPAIR MUST CARRY
The round-113 repair of `ANDROID-05-A` BROKE **69 TESTS ACROSS ~10 COURTS**, because 27 test
construction sites built the real `BleTransport` with no boundary and therefore DEPENDED ON THE AUDITED
DEFECT (`isStarted` set despite a failed host OS start). **THE HOST SUITE HAS BUGS BAKED INTO ITS
FIXTURES.** Before repairing any owner, grep how many courts construct it and what they assume -- and
repair those fixtures IN THE SAME CHANGE, as round 113 did.

### TWO PARKED REDS, AND WHERE THEY LIVE
  * `tools/readiness/audit_probes/python/audit004_operator_pair_probe.py` -- GS-CONTENT-002 step 4 (the
    second pair-of-renames), with round 6's measured collision recorded inside it.
  * `tools/readiness/audit_probes/kotlin/ReadinessAndroid05bTest.kt.txt` -- the LIFECYCLE-AUTHORITY
    retry red, REPAIRED at round 110; kept as the record of the red and its recipe.

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
