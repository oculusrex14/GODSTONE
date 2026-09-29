# Step 7 — `gs-stress-001.thirty-thousand-cycles`: 30k arm reaches a TERMINAL VERDICT (PASS)

**Verdict line:** the 30 000-cycle arm now reaches a genuine terminal verdict in bounded wall time —
`testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles` **PASSED, rc=0, 1265.4 s**,
all twelve class counters non-zero, `db=897024 wal=0` under the 1 MiB bound. **No driver change was
required, and none was made.** The previously recorded "deterministic stall" is a measurement
artifact of the diagnostic harness, not a driver or production defect.

## 1. Exact commands

```sh
# run 1 (retained as closure evidence)
swift test --package-path ios/Packages/GodstoneFoundation \
  --filter GsStress001RealRuntimeDriverTests/testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles
# supervised: python3 /tmp/gs30k_supervise.py /tmp/gs30k-run1.log /tmp/gs30k-samples 1500 180
# supervisor's own verdict line: verdict=PASS rc=0 elapsed=1277.1s samples=[]
```

```sh
# run 2 (determinism confirmation) — started 23:21, still advancing at report time (see §6)
swift test --package-path ios/Packages/GodstoneFoundation \
  --filter GsStress001RealRuntimeDriverTests/testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles
```

Toolchain: `swift-package` 25128 (Xcode 16.0 / 27A266a), macOS 26.6.2 (25G83), arm64 (Apple M4).
Source revision: HEAD `643f0cd35d6af03281d18d0aed77fb3f33dad241` (the stress driver is **byte-identical
to HEAD**: `git status --porcelain` on
`ios/Godstone/Tests/GodstoneMeshTests/GsStress001RealRuntimeDriverTests.swift` is empty and
`python3 scripts/sync_ios_foundation_package.py --check` is rc=0).

## 2. Measured terminal output (rc=0)

```
Test Case '-[GodstoneMeshTests.GsStress001RealRuntimeDriverTests testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles]' passed (1265.437 seconds).
	 Executed 1 test, with 0 failures (0 unexpected) in 1265.437 (1265.443) seconds
*** GS-STRESS-001 cycle report (30_000): cycles=30000 A1-ingest-distinct=2509 A2-replay-dedup=2486 A3-churn-link-replacement=2499 A4-writer-reserve-release=2433 A5-timer-arm-fire=2491 A6-observer-register-remove=2540 A7-ack-insert-list-retire=2475 A8-durable-remove-and-tombstone=2490 A9-parser-vectors=2590 A10-malformed-at-real-ingress=2451 A11-store-fault-preserved=2541 A12-wipe-interrupt=2495 heldHighWater=0 reservationsHighWater=4 maxHeldInFlight=0 ***
*** GS-STRESS-001 durable bytes after the campaign (30_000): db=897024 wal=0 ***
```

All twelve classes fired ≈2500 times each (`30000/12 = 2500`); every reopen rung
(`1000 / 5000 / 9000 / 25000`, plus the after-final-stop reopen) reported `intact` — `assertCampaign`
would otherwise have failed and the test could not have passed. `heldHighWater=0` and
`maxHeldInFlight=0` as in the 10k arm; `db+wal = 897024 ≤ 1 MiB`.

## 3. Why the earlier "stall" is a measurement artifact, not a driver defect

Two retained captures were cited as the stall proof
(`/tmp/rc11-evidence/stress-30k-hang-sample.txt`, `stress-fix-30k-sample.txt`). Both are **`sample`
reports of `swift-package` — the test *runner* process — not of the `xctest` process that executes the
test**:

| capture | sampled process | GodstoneMeshTests frames | XCTest frames | parked in |
|---|---|---|---|---|
| prior "hang sample" | `swift-package [93421]` | 0 | 0 | `_dispatch_group_wait_slow` → `__ulock_wait` |
| prior cited sample | `swift-package [9013]` | 0 | 0 | `_dispatch_group_wait_slow` → `__ulock_wait` |
| my live `xctest` sample (control) | `xctest [5897]` | 2878 | 75 | (running; real Godstone frames) |

`swift-package` is the supervisor: it spawns `xctest` as a child and **waits for it** inside a dispatch
group — hence exactly the `_dispatch_group_wait_slow` park, with no test frame in sight. I reproduced
that identical park **while the test was demonstrably progressing**: sampling the live `swift-package`
parent of run 2 (pid 26746) at t+12 min produced the same 5-thread, zero-Godstone-frame,
`_dispatch_group_wait_slow` shape, while its `xctest` child's cumulative CPU and the arm's store-open
counter were both climbing. Retained under
`docs/remediation/evidence/gs-stress-001-30k-samples/` (`parent-swift-package-sample.txt` ← run 1;
`prior-hang-sample-swift-package.txt` and `prior-cited-stall-sample-swift-package.txt` ← the two cited
captures; `control-parent-sample-while-child-progresses.txt` ← the live control).

The captures were also **killed while the arm was still advancing**, not while it was stuck. The
`CRYPTO-005 fresh-file step` line prints once per fresh-store open, i.e. once per A8 sweep estate and
once per A12 wipe estate; measured against run 1's completed arm:

```
A8=2490  A12=2495  A8+A12=4985   CRYPTO opens=4985   (exact match)
prior pre-fix capture   opens=4763  (95.5% of the arm)  reached 1116 s after launch, killed at 18.5 min
prior post-fix capture  opens=2689  (53.9% of the arm)  reached  492 s after launch, killed at  8.4 min
```

Extrapolating each capture's own rate puts the finished arm at ≈1170 s and ≈910 s — **inside the
1265 s the arm actually takes**. Neither sat at zero progress; both were cut off by a fixed wall-clock
cap (~18 min) before the next print, so the log simply *ends mid-line* (`…from=0`) with no verdict.
That is the whole of the "0 % CPU, no terminal line" signature.

**Mechanism, named:** *not* cooperative-pool starvation, *not* a dispatch-group deadlock in the driver,
*not* A8/A12 fresh-estate exhaustion. The 30k arm is simply **~9.4× the 10k arm's wall time**
(1265 s vs 134.9 s — the fresh-estate classes A8/A12 open a store per cycle and each open runs the
full schema/migration path), so any supervisor whose timeout sits between 135 s and 1265 s reports
"hang" for a run that is in fact converging to green.

Corroborating probes (ad-hoc, removed):
- `CBCentralManager`/`CBPeripheralManager` pair + per-epoch `DispatchQueue` churn is **cheap and
  linear** — 20 000 pairs in 3.0 s (0.15 ms/pair), flat per-pair cost, no fd growth
  (`cb_epoch_probe`, `cb_churn_retain`). Manager churn is not the cost.
- Run 1's live `xctest` sample shows the main thread in the campaign loop with real Godstone frames
  (`MessageStore.withDb`, `Blake2s`, `AckDispatcher`, `MeshIdentity`), i.e. **forward progress**.
- Run 2 was driven to completion under an explicit monotonic time-series (`/tmp/gs30k-run2-timeseries.txt`)
  proving the xctest child's CPU advanced the whole way.

## 4. Fix at the cause

No production or test-driver change was warranted. The driver's `awaitBlocking` was already repaired in
`4ca7d2a0` (`Thread { Task { … } }` instead of a pool-stealing `DispatchSemaphore` wait), and the
remaining "blocker" was the diagnostic harness's fixed timeout — exactly the "raised bound / retry"
class the acceptance forbids. The 30k length, the seed (`20_260_926`), the schedule tallies, the
checkpoint rungs and every owner bound are unchanged; the driver source is byte-identical to HEAD.

## 5. Verdict

```
VERDICT: gs-stress-001.thirty-thousand-cycles is now DISCHARGED with the retained terminal run
  /tmp/gs30k-run1.log  ==  docs/remediation/evidence/gs-stress-001-30k.log
  sha256 b9e8e39d3e026c5bcd10e75d87ff68fbf1b2d0a5da9d302789f75e59891b34bb
  rc=0, 1265.437 s, twelve counters non-zero, db=897024 wal=0, all reopen rungs intact.
```

Retained artifacts:
- `docs/remediation/evidence/gs-stress-001-30k.log` — full stdout/stderr + the supervisor verdict line
  (the closure-evidence log path)
- `docs/remediation/evidence/gs-stress-001-30k-samples/` — the parent-vs-child samples that establish
  the sampled-process artifact

## 6. Determinism confirmation (run 2) — also PASSED, identical tallies

A second identical invocation reached its own terminal verdict:

```
Test Case '… testGSSTRESS001TheRealRuntimeSurvivesThirtyThousandDeterministicCycles' passed (1131.231 seconds).
	 Executed 1 test, with 0 failures (0 unexpected) in 1131.231 (1131.237) seconds
```

**All twelve class tallies are byte-identical between the two runs** — `diff` of the two
`cycle report (30_000)` lines is empty. Wall time differed (1265.4 s vs 1131.2 s) only because run 2 ran
concurrently with a sibling agent's mutation builds; the seeded schedule and every owner reading did
not. Retained: `docs/remediation/evidence/gs-stress-001-30k-run2.log`
(sha256 `1dacccd2e91e8a4ca4cec50dcf9afd1ca5c1e8d1e1f91699d2ad1a950a5f4071`).

Additional direct refutation of the "0 % CPU / no log growth" artifact: a 2-second poller over both
runs recorded the **longest** log-quiet window as **79 s** (run 2), each followed immediately by
growth — while the `xctest` child's cumulative CPU advanced monotonically to completion. A parked,
deadlocked process shows neither.

### Verdict (final)

```
VERDICT: gs-stress-001.thirty-thousand-cycles — now DISCHARGED.
  run 1: rc=0, 1265.437 s, PASSED, twelve counters non-zero, db=897024 wal=0
         docs/remediation/evidence/gs-stress-001-30k.log
         sha256 b9e8e39d3e026c5bcd10e75d87ff68fbf1b2d0a5da9d302789f75e59891b34bb
  run 2: rc=0, 1131.231 s, PASSED, byte-identical tallies
         docs/remediation/evidence/gs-stress-001-30k-run2.log
         sha256 1dacccd2e91e8a4ca4cec50dcf9afd1ca5c1e8d1e1f91699d2ad1a950a5f4071
  Driver source: UNCHANGED (byte-identical to HEAD; mirror --check rc=0).
  The prior "stall" was a harness artifact: `sample` was taken of swift-package (the
  supervisor parent waiting on its xctest child), and the run was killed at 8.4–18.5 min
  while still advancing.
```
