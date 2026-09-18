# Adopted audit probes — the RED harness for waves 3a and 8

`test_audit_artifacts.py` is the audit's own 12-case final suite
(`AUDIT_FINAL_2026-09-15/evidence/AUDIT-003/audit_final_negative_tests.py`) adopted with its
assertions intact. **Seven of its twelve arms are RED on this tree**, which is the point: they are
the reproduced defects of

| Finding | Red arm | Observed |
|---|---|---|
| GS-SUPPLY-001 | parent traversal / source symlink | `{"rejected": false, "wrote_outside_destination": true}` |
| GS-DIAG-001 | unique peer churn | `{"ring": 16, "retained_relation_keys": 10000}` |
| GS-PACKAGE-001 | forbidden signed entitlement / arm64 macOS binary | `{"verdict": "PASS", ...}` |
| GS-PACKAGE-002 | corrupt / partial AAB native libraries | `{"verdict": "PASS", ...}` |

The five arms that already pass are the suite's own POSITIVE CONTROLS — a valid cache restore,
changed bytes refused, a bounded ring, a valid source bundle and a valid APK — so the red suite is
not one that refuses everything.

## Why this directory and not `tests/`

`python3 -m unittest discover -s tools/readiness/tests` is the GREEN lane: it must never be red.
A probe that is red BY DESIGN therefore liveth here, and **each finding's repair MOVES its arm into
`tools/readiness/tests/` as it lands** — the card's "move the independent failing assertion into
the canonical subsystem suite" is part of the REPAIR, not a preliminary. When the last arm of a
probe is green, its file moves; the directory disappears with them.

Run them with:

```
python3 -m unittest discover -s tools/readiness/audit_probes -v
```

## Kotlin probes — `kotlin/ReadinessModel001Test.kt` (GS-MODEL-001)

This file liveth OUTSIDE the Gradle test source sets **on purpose**: Gradle runneth every test source
in a module, so a red-by-design Kotlin arm inside `android/llm/src/test/java/...` would redden the
`:llm` lane and the android lane with it -- the same self-inflicted red this program eliminated for the
python probes. It was RUN in its module to capture the red (the log is the finding's), and it is put
back only when its repair landeth.

**To run it (and it MUST be red before the repair):**

```
mkdir -p android/llm/src/test/java/io/godstone/llm/readiness
cp tools/readiness/audit_probes/kotlin/ReadinessModel001Test.kt android/llm/src/test/java/io/godstone/llm/readiness/
cd android && ./gradlew :llm:testDebugUnitTest --tests '*ReadinessModel001Test*' --no-daemon
```

**Captured red** (product untouched, `1965d60`): 2 tests, 2 failures --
`an EXISTING GARBAGE model was accepted without a sworn artifact: the audit's reproduced defect
(GS-MODEL-001)` and `an unpinned stream of 64 MiB was accepted whole`. When the repair landeth, the
file MOVES BACK into the module as its permanent control, exactly as the python probes do.

## Swift probes — `swift/ReadinessStore003Tests.swift` (GS-STORE-003)

Red by design, and parked OUTSIDE the mirrored package for the same reason as the STORE-002 probe: `swift
test` is the only runnable Swift lane here, and a red arm inside it would redden the package lane.

**Captured red** (product untouched): 3 tests, 3 failures -- the versioned migration `DROP TABLE`s durable
tables, `SchemaMigration` is NOT bound to it, and the destructive path is not named as the never-shipped
pre-ship case. The audit's own behavioural probe (persist a real row, versioned reopen, the row VANISHES) is
named in the ledger as the arm still owed.

**To run it:** copy into `ios/Godstone/Tests/GodstoneMeshTests/`, run
`python3 scripts/sync_ios_foundation_package.py`, then
`swift test --package-path ios/Packages/GodstoneFoundation --filter ReadinessStore003Tests`.

## Swift probe — GS-SOS-001's iOS twin: LANDED, and the parked patch is gone (round 162)

The arm that was parked here as `swift/gs-sos-001-ios-twin.patch` has **MOVED INTO THE CANONICAL SUITE**, as
this directory's rule requireth: `MissingMaterialAuthority`, the behavioural arm, and the REVERSAL of
`ReadinessT38Tests`' own legacy arm now live in
`ios/Godstone/Tests/GodstoneMeshTests/ReadinessT38Tests.swift` (and its mirror), and the refusal liveth in
`MeshNode.dispatchSos`'s `else` branch. The parked patch was deleted with the repair in the same round, so
nothing here carrieth a red arm that duplicates a green one.

**Its captured red stayeth on the record** (product untouched, detached pre-repair worktree at `95dc75e`,
log `REMEDIATION/GS-SOS-001/ios-red-round161/red.log`): `12 tests, with 6 failures (0 unexpected)`,
`0 errors` — the build succeeded, so every failure was an assertion. The null-yield arm reported one durably
held frame, one C6 row and `queuedDurably` instead of a refusal; the reversed legacy arm reported the same for
an unwired node. **The arm's `sends == 0` assertion passeth on BOTH sides of the repair** (zero peers means the
send closure is never invoked), so the discriminating assertions were the durable hold, the C6 row and the
typed refusal — stated so that a non-discriminating count is not later mistaken for evidence.

The repair's green, for the record: `Executed 1196 tests, with 0 failures (0 unexpected)`, `0 errors`
(`REMEDIATION/GS-SOS-001/ios-green-round162/green.log`).

## Python probe -- GS-SOS-001's issuance bypass, the iOS half: LANDED (round 164)

The parked iOS arm has **MOVED INTO THE CANONICAL SUITE** beside its Android twin
(`tools/readiness/tests/test_local_identity_issuance.py`), as this directory's rule requireth, and the
parked file was deleted with the repair in the same round -- so nothing here carrieth a red arm that
duplicates a green one. Its captured red stayeth on the record at
`REMEDIATION/GS-SOS-001/issuance-red-round163/ios-parked-red.log`.

With both halves landed, `ci/check_local_identity_controls.py` (which reported TWO errors on the audited
tree) reporteth NONE, and its selftest still catcheth 38 of 38 mutations -- so the instrument that was
always working now agreeth with the code.

## Python probe — ANDROID-05 step 3's in-flight drain: LANDED (round 183)

The parked arm has **MOVED BACK INTO THE CANONICAL SUITE**
(`tools/readiness/tests/test_lifecycle_inflight_drain.py`), as this directory's rule requireth, and the parked
file was deleted with the repair in the same round. Its captured red stays on the record at
`REMEDIATION/ANDROID-05/red-round182/red.log` (`Ran 4 tests, FAILED (failures=3)`, with the W00 positive control
passing). The repair: a NEW `InFlightAwareTransport` capability, `LifecycleTransportAdapter.awaitInFlight`
overriding the seam's do-nothing default and delegating through `as?`, and `BleTransport` implementing it with a
MEASURED bounded count over its own in-flight work.

## Kotlin probe — ANDROID-07 / T26 step 2's full-NodeID witness: LANDED (round 193)

The parked witness has **MOVED INTO `ReadinessT17Test`** (the court whose rig owns the real trusted handshake), and
the parked file was deleted with the repair. Its story is worth keeping, because the witness judged a MEASUREMENT and
not an absence: rounds 191–192 established that `SessionManager.authenticatedNodeIdOf` could not derive the identity
from the live session (the Noise remote static is the peer's STATIC DH key, and the NodeID derives from the SIGNING
key), and that the identity lives in the VALIDATED BINDING the controller consumed without retaining it. Round 193
added the retention, and the witness — keyed on the CONNECTION's `peerId`, a correction the diagnosis itself produced
— now asserts the identity is the peer's OWN sixteen-octet NodeID, after trust and never before.

## Python probe — `python/test_ios_governor_serialisation.py` (IOS-05 / T27 step 5): LANDED (round 194)

Written and **run RED first** in this directory (`Ran 3 tests, FAILED (failures=2)`, W00 control passing) and then
**MOVED INTO `tools/readiness/tests/`** with the repair, as this directory's rule requires. It judged the iOS
`PeerGovernor`: `reward`/`penalise` mutated a **shared `Trust` reference** after `mutableTrust` had released
`registryLock` — and its third arm asserted the repair must add a **lock-held** lookup, because the lock is an `NSLock`
(not recursive) and a naive fix would **deadlock**. That arm is why the repair was written once instead of twice.

## Python probe — `python/test_ios_post_aead_charge.py` (IOS-05 / T27 step 3): LANDED (round 198)

Written and **run RED first** in this directory (`Ran 4 tests, FAILED (failures=3)`, W00 control passing — and that
control then **caught its own author**, having asserted the Android spelling where the isle writes `.authenticated(`),
which is what a positive control is for). It judged the iOS post-AEAD road: two collectors handing the plaintext to the
delegate **uncharged**, and a controller consuming the validated binding **without retaining it**. The five-site repair
landed in round 198 and the arm **MOVED INTO `tools/readiness/tests/`** with it, as this directory's rule requires.

## Python probe — `python/test_ios_governor_under_runtime_owner.py` (IOS-05 / T27 step 1)

Red BY DESIGN, parked here while the decision it exposes is made. It asserts the card's step 1 in its own words —
"one governor configuration ... under the runtime owner" — and the isle currently carries **two** instruments: the
purpose-built `AdmissionBudget` (rounds 196–198) and a `PeerGovernor` **referenced nowhere in production but one
comment**, whose identity/priority buckets are charged at **no** gate. An attempt to wire it (round 201) exposed a real
design tension — the governor's canonical buckets are **per-second frame buckets** (DIRECT 60, SOS 30, BROADCAST 20,
BULK 10, unknown 10) while this gate sees **whole records** (a 257-record wrap, a 64-fragment record) — and the attempt
was **withdrawn on a contaminated measurement** rather than shipped. The two courses (charge the governor's *trust* gate
per value and leave rate to the router, or give the transport a documented transport-scoped configuration) are named in
the ledger; the next attempt measures with the failing names captured in ONE clean run.

## Python probe — `python/test_ios_governor_under_runtime_owner.py` (IOS-05 / T27 step 1): LANDED (round 202)

Written and **run RED first** here (2 failures, W00 control passing), then **MOVED INTO `tools/readiness/tests/`** with the
repair, per this directory's rule. Its history is the useful part: round 201 attempted the governor's **buckets** per value
and **withdrew on a contaminated measurement** (a compile-failed attempt shared a log with a later run, so the three
failing names were never captured — and were therefore **not claimed**); what that attempt exposed is that the canonical
buckets are **per-second frame buckets** while the post-AEAD gate sees **whole records**. Round 202 therefore implemented
**course (a)** — the governor's **trust** question per value (`admits`, no tokens consumed), leaving **rate** to the router
— and proved it with **ONE clean run**: `Executed 1203 tests, with 0 failures`.

## Python probe — `python/test_lease_sweep_owner.py` (ANDROID-04): LANDED (round 204)

Written and **run RED first** here (3 failures, W00 control passing), then **MOVED INTO `tools/readiness/tests/`** with the
repair. It judged the transport's lease sweep: `sweepInboundLeases()` was called **only by a court**, so a **silent** peer's
lapsed absolute term waited for unrelated traffic. The repair gave the sweep a **production owner** — armed at `start()`,
cancelled at `stop()`, a named generous interval — and the arm now also asserts the interval is named and **not** short
enough to sweep frozen-clock courts mid-witness.

## Kotlin probe — `kotlin/t20-owned-sweep-time-witness.kt.txt` (ANDROID-04, the time-based witness)

**WHICH SUFFIX MEANS PARKED.** A probe that must stay RED carries the **`.txt` suffix** (`…Tests.swift.txt`,
`…Test.kt.txt`), because Swift and Gradle compile every source in a module: a `.swift`/`.kt` file here would be compiled
if it were copied, but as `.txt` the harness and the discovery walkers skip it. A probe WITHOUT the suffix
(`python/test_*.py`) is a Python arm, which `discover` DOES collect — those live here only while RED and move into
`tools/readiness/tests/` when the repair lands.

Parked with its **measurement**, not merely its failure. The witness drives the owned lease sweep by **time alone** (an
injected clock past the lease's deadline, a **25 ms** interval, **no** traffic) and asserts the silent relation retires. It
was RED — and **its diagnostic assertion passed**, proving the job **is armed** (`hasLeaseSweepJob()` true) and ticking —
while the T20 court's own arm trips the **same** relation with the **same** clock by calling `sweepInboundLeases()`
**directly**. **The difference is therefore the caller's thread**, and the leading hypothesis is the `runCatching` around
the job's sweep **swallowing an IO-dispatcher exception**. Next step: make that failure **observable** (record the throwable
into the transport's own rejection census) and read what it says — a measurement, not a guess. The `leaseSweepIntervalMillis`
seam it needs **already landed** (round 206).

## Python probe — `python/test_connection_clock_monotonic.py` (ANDROID-04 step 1): LANDED (round 208)

Written and **run RED first** here (W00 control passing after it caught its **own** miscount; the two defect arms
failing), then **MOVED INTO `tools/readiness/tests/`** with the repair. It judged the connection's lease clock: the
`BleOrchestrationDriver` created **every** connection with `connectionClockForTest ?: { System.currentTimeMillis() /
1000L }` — a **wall clock** against which every lease deadline is computed, at **two** sites. The repair makes both
monotonic (`System.nanoTime() / 1_000_000_000L`, seconds stated). The arm **strips comments before matching**, because a
first draft banned the spelling across the whole file and tripped on the audit-trail comment the repair itself wrote —
the same trap the repository's identity control taught at round 163.

## Kotlin probe — ANDROID-04's time-based witness: LANDED (round 210)

The parked witness **MOVED INTO `ReadinessT20Test`** as `testTheOwnedSweepTrippethASilentPeerByTimeAlone`, and the parked file
was deleted with it. Its history is the useful part, and it is all in the ledger: the **seam** (an injectable 25 ms
interval) landed in round 206; the first attempt was **RED**; round 207 **refuted** the fixture-clock hypothesis by making
the fixture's clock `@Volatile` (no change) and then **found** the wall-clock connection default; round 208 **fixed** that
(and the sweep's silence survived it); round 209's **counters** refuted the iteration/visibility hypothesis (`seenJob=13`)
and **displaced** the suspicion onto the witness's own setup (`directSeen=1 retiredAfterDirect=false`); and round 210
built the arm **verbatim on the court's own working setup, differing in exactly one way** — not calling
`sweepInboundLeases()` — and it **PASSED**. **Two plausible hypotheses were refuted by measurement rather than argument,
and neither cost anything but an instrument.**

## Python probe — `python/test_ios_deadline_sweep_owner.py` (IOS-07)

Red BY DESIGN, parked while the repair lands. It asserts that `BleTransport.sweepInboundLeases()` (:2827) — which walks the
outbound and inbound lifetimes, asks each connection whether a lease lapsed, and retires the **owning** relation through its
**exact key** — has a **scheduled production owner**; today it is called by **nothing** in production (its only caller is a
court, `ReadinessT20Tests:1000`), so a **silent** peer's lapsed handshake/assembly/confirmation deadline waits for unrelated
traffic for ever. **This is the same defect ANDROID-04 closed at round 210**, and the repair is the same shape: a named,
injectable interval; a `leaseSweepJob` armed in `startInstalling()` (past the `isStarted` guard) and cancelled at the top of
`stop()`; and the instruments five rounds of Android method proved necessary (ticks / relations seen / leases lapsed, plus
`hasLeaseSweepJob`). **Round 211 wrote and compiled that repair and then WITHDREW it**, because the controlled-experiment
witness hit a compile error the round had no budget to settle — and a production change whose lane run was never completed is
**not verified**. The three anchors and the witness's one obstacle are recorded in the ledger so the next attempt is an edit.

## Python probe — `python/test_ios_deadline_sweep_owner.py` (IOS-07): LANDED (round 213)

Written and **run RED first** here (3 failures, W00 control passing), then **MOVED INTO `tools/readiness/tests/`** with the
repair. It judged the iOS isle's **silent-peer deadlines**: `BleTransport.sweepInboundLeases()` walked the outbound and
inbound lifetimes and retired the **owning** relation through its **exact key** — and was called by **nothing** in
production, so a silent peer's lapsed deadline waited for unrelated traffic for ever (the twin of ANDROID-04). The repair
gave it a **production owner** (a named, injectable interval; a `leaseSweepJob` armed in `startInstalling()` and cancelled
in `stop()`), and the **controlled-experiment witness** — the court's own working expiry arm **verbatim**, differing only in
a 25 ms interval and in never calling the sweep — proved the owned job trips a silent peer **by time alone**.
