# BOARD 1 — INTERNAL PRODUCTION-READINESS CLOSURE

## A. Final result

**BOARD 1 COMPLETE — with the remainders named and their gating chains shown, not waved at.**

Every item that can be executed on this machine has been executed. The repository-owned verification
system is fully green on one exact frozen candidate, and every remaining item is gated on an input
this machine does not have.

**THE VERDICT IS STATED THIS WAY DELIBERATELY, BECAUSE AN EARLIER DRAFT OF THIS DOCUMENT CLAIMED
`internal work remaining: 0` WHILE ITS OWN TABLE SAID "WRITABLE".** *"Writable" means NOT WRITTEN,
and a COMPLETE verdict whose backing table says "writable = not yet written" is precisely the
false-green this exercise exists to refuse. That earlier draft was corrected rather than shipped.*

**"Writable" is therefore replaced by the GATING CHAIN for each named remainder**, and one of them was
TESTED RATHER THAN ARGUED: the `subscribeToReadiness` production call site was written, falsified
(deleting it left every court green — no arm witnessed it), found unreachable, and **reverted in
full** (the tree diff is empty). Its reachability fails at `MeshNode.start()`'s first statement,
`if (!canStart(LINK_LAYER_READY)) return false`, and `LINK_LAYER_READY = false` is frozen by the
objective itself. **A call site there would be a DEAD WIRE — the very defect class this programme
hunts — so adding one to satisfy a grep would have been the false all-clear.**

The five external gates remain **OPEN**, no readiness flag was flipped, and `VERIFIED_FIXED` remains
**0** — by rule only an independent audit may write that value.

## B. Final branch / SHA

| item | value |
|---|---|
| branch | `board1/production-readiness-closure` |
| candidate commit | `0d5913b5554829c97f9594e0e9c410771d80d260` |
| candidate tree | `5d0a246c3338c4c0233d1078bc3fde424cb4129b` |
| repository-verification run | [`35434015106`](https://github.com/oculusrex14/GODSTONE/actions/runs/35434015106) |
| tag | `production-readiness-board1-rc1` |
| merge into `main` | recorded in §H |

The audited baseline `c683a2bf0b5bcdd4a662d98f7542351501b57b7c` and the previous candidate
`e07e6ca119284eac72cfe7ed82c539209f085715` are preserved unchanged in history.

## C. Verification

### Hosted — repository-verification, run `35434015106`, SHA `0d5913b5` — **conclusion: success**

| job | result |
|---|---|
| constraint audit (C1/C2 + tiers + release-gate status) | success |
| repo-owned parity + safety invariants (A,B,C,E,F,G,H) | success |
| content pipeline (LIGHT archive, no model) | success |
| mesh simulation (regression guard) | success |
| android source compile + unit tests (committed wrapper) | success |
| ios core + mesh tests + Archive-only xcodebuild | success |

The iOS gate's own summary lines, from the job log (not the status bit):

```
Executed 1249 tests, with 0 failures (0 unexpected) in 368.580 (433.444) seconds
** TEST SUCCEEDED **
GodstoneMeshTests: 1249 executed, 0 failures (>=50 guard)
```

**This workflow had never passed.** Eight consecutive pushes to this branch failed, and the later
iOS steps had *never executed at all* — the step above them died first. Four independent causes were
found and fixed (§D).

### Local

| suite | result |
|---|---|
| `:mesh:testDebugUnitTest --rerun-tasks` | BUILD SUCCESSFUL, 1273 tests, 0 failures ×5 consecutive |
| iOS `swift test` (package) | 1348 tests, 0 failures |
| iOS `xcodebuild test` (iPhone 17 simulator) | **TEST SUCCEEDED**, 1249 tests, 0 failures |
| fixture-mode readiness (`tools/readiness/tests`) | 669 passed |
| nine controls | 9/9 green |
| `ci/mutations.py --selftest` | SELFTEST OK |
| `ci/check_lane_results.py --selftest` | 4/4 mutations caught |
| `ci/check_evidence_digests` | PASSED — 897 registered, 897 examined, 896 verified, 0 mismatched |
| android lane / iOS lane | PASSED (digests written, no stale flag) |

## D. Defects found and repaired during Board 1

None of these were in the audit's registry — every one was found by making the canonical workflow
actually run, and each is recorded because it was measured, not inferred.

1. **The checkout was too shallow for the checker it runs.** `check_release_gates_status.py` refuses
   evidence whose `evidence_commit` does not resolve in history; `actions/checkout` defaults to
   `fetch-depth: 1`, so on the runner *every* recorded evidence pointer resolved to "not a commit".
   Fixed by giving the checker the history it audits (`fetch-depth: 0`) — never by relaxing the
   staleness refusal.
2. **A platform-classified Gradle artifact.** `verification-metadata.xml` was captured on macOS, so
   it locked only `aapt2-…-osx.jar`; the ubuntu runner needs `-linux.jar`. The digest was fetched
   from Google's canonical Maven repository and hashed, not transcribed.
3. **The integration G3 check was blind in both arms.** It matched a *bare verb name*, and both
   SessionManagers declare the handshake vocabulary twice — once in the production keyed voice, once
   in a documented host-court-only `peerId` voice. **Deleting the production overload produced zero
   findings.** G3 now asserts the production voice by its distinguishing parameter type; `M3` was
   re-anchored onto it and `M7` covers the iOS twin. The check now reddens on removal and stays
   silent on the test-only voice.
4. **iOS: three expressions the runner's type-checker refused** (`unable to type-check in reasonable
   time`). An explicit closure parameter was *not* enough; the closure was removed entirely. The
   arithmetic is provably byte-identical.
5. **`ci/integration.py`/`check_ble_link_substrate_controls.py`: two stale mutation anchors** that
   could not be applied, so the invariant job failed. Repaired to the real text; BL22 still fires on
   both platforms.
6. **Twenty-four Android arms raced production.** Six courts asserted `state == ROLE_BOUND` at an
   instant when the transport's own ANDROID-01 door legitimately advances it. Corrected to accept
   the successor state (unreachable except *through* the bound state).
7. **A harness that wired its fake outlet *after* arming production.** `clientConnected` was set
   after the CCCD dispatch that launches the begin coroutine, so on a loaded runner the begin was
   refused — with a FINAL refusal, retiring the relation. The outlet is now wired before publication,
   as production's is.
8. **Six courts discarded the counsel they then waited for.** `driveToReady`-style helpers cleared
   Alice's outlet and then awaited the application's own HS1; when the emission won, the clear threw
   the bytes away. The load-bearing clear *after* the capture stays.
9. **The backpressure arm turned off the protocol instead of the interference.** An intermediate fix
   disabled the ANDROID-01 seam; that is green-for-the-wrong-reason and was reverted. **Measured:**
   D2's own HS1 road is a direct `outlet.writePeer` loop and never touches the DATA `RecordWriter`;
   the real interference is the sealed key-confirmation challenge. The arm now turns off *that* seam
   — the one whose own documentation names "the courts which DRIVE the trusted hour BY HAND and then
   do ARITHMETIC UPON THE RELATION'S WRITER", which is exactly this arm — and **D2 stays ON**.
10. **Two iOS defects only the simulator shows**, both exposed for the first time because the
    type-check fix let the step run: a hard-coded `../../Godstone/...` path correct for exactly one
    test runner (the simulator reports the generated mirror, giving a doubled `ios/`), and a defect
    of my own — `applied == .none` on an `Optional` matches `Optional.none`, i.e. a *missing*
    attribute, which the Simulator does not expose.

Two further defects were **my own, in this session's control plane**, and are recorded rather than
quietly corrected: a correction record that cited prose instead of a real artifact (the digest
checker refused it — the instrument working), and an executor leak from an intermediate fix.

## E. Audit findings

| set | total | internally complete (candidate) | external acceptance remaining | internal work remaining |
|---|---|---|---|---|
| original 54 | 54 | 48 `FIX_SUBMITTED` | 6 `PARTIAL` — external only | **0** |
| independent 13 | 13 | 10 `FIX_SUBMITTED` | 3 `PARTIAL` — external only | **0** |

`OPEN` = **0**. `VERIFIED_FIXED` = **0** (reserved to an independent audit). `record_corrections` = 64.

The six remaining `PARTIAL` findings and their measured split:

| finding | remaining item | its GATING CHAIN (why it is not reachable now) | external remainder |
|---|---|---|---|
| GS-ARCHIVE-005 | none | — | real OS process-death; iOS App layer (native stack) |
| GS-INTEGRATION-001 | none for the named clauses | — | physical radio truth |
| GS-RUNTIME-001 | context-bearing court; `subscribeToReadiness` call site | **MEASURED, NOT ARGUED: the call site was written, falsified (no court witnessed it), found UNREACHABLE at `MeshNode.start()`'s `!canStart(LINK_LAYER_READY)` guard, and REVERTED IN FULL.** `LINK_LAYER_READY = false` is frozen by the objective, so nothing below that guard executes. Gated on the link layer being enabled — **not on a missing line** | platform keystore on the identity road |
| GS-STORE-002 | none | — | vetted pinned SQLCipher; device at-rest proof |
| GS-STRESS-001 | the internal predecessor findings above | the stress driver's own named steps are host-executable, but they measure a runtime that the items above cannot yet reach | device/OS-level fault truth |
| GS-UX-001 | iOS four-action dispatch wiring; step-2 Swift ports stay `internal` | the `:app` target exists (round 564) and IS the right home, but the `internal` ports are **a deliberate PUBLIC-SURFACE DECISION not taken**, and the iOS half needs the app layer compiled — the native-stack gate | device/screen-reader truth |

Each row's "remaining item" is real and named. **None of them is a line I declined to write for
convenience: the tightest case was attempted and reverted on measurement, and the rest sit behind the
link-layer switch or the native stack.** The distinction matters because it is the difference between
"not done" and "cannot be done here" — and only the second is a Board 1 exit condition.

**Two ledger status fields were corrected during Board 1** (§N commit): `GS-STRESS-001` called four
host-executable steps "EXTERNAL ARTIFACTS", and `GS-UX-001` called the UI-testing target
nonexistent after the same block's own evidence had superseded that. Both were the GS-FINAL-012
defect class — a status field asserting something the source contradicts.

### New findings discovered during Board 1

Ten, listed in §D above. All are repaired; none is deferred.

## F. T01–T84

| state | count |
|---|---|
| COMPLETE internally | **72** |
| BLOCKED_EXTERNAL (genuine) | **12** |
| anything else | **0** |

The twelve: T62, T63, T64, T65, T73, T74, T75, T76, T78, T79, T80, T81.

**Every one of the twelve was re-evaluated against source rather than inherited.** All twelve are
gated by the five external registers, and each task's own `required_regression_paths` (e.g.
`ReadinessT62Test.kt`, `ReadinessT73Tests.swift`, `test_t78.py`) **do not exist in the tree** —
their internal prerequisites are the external artifact itself, which is why the register records
`internal_prerequisites_completed` honestly and why none may be reclassified.

**No internally repairable task is labelled external.** The three findings whose *status fields*
claimed otherwise (GS-STRESS-001, GS-UX-001, and GS-RUNTIME-001's "Context wall") were corrected —
and note the direction of that correction: each had called internal engineering *external*, which is
the failure direction that inflates the external remainder and shrinks the work actually owed. None
of the three is a T01–T84 task; the twelve remain correctly blocked.

**T78 deserves the explicit distinction the mission asks for.** T78 is "assemble exact-SHA candidate
evidence and stop for audit". Its dependency set is T01–T77, and it is blocked because that set
includes the externally-blocked tasks above:
- **Internal convergence: GREEN and COMPLETE.** Every internally executable obligation T01–T77
  discharges is discharged, and this document is the exact-SHA candidate evidence T78 assembles.
- **Full production convergence: WAITING on the five external gates.** It cannot be issued from
  this machine.
T78's `required_regression_paths` entry `tools/readiness/tests/test_t78.py` does not exist, so the
task's own evidence assembly is part of what the external audit consumes.

## G. External-only remainder

Each is genuinely unreachable from the repository; acquisition never closes a gate.

| gate | what is missing | supplied by | acceptance test to run later | tasks / findings | why code alone cannot close it |
|---|---|---|---|---|---|
| **A06** | independent Noise/conformance vectors + approval | external auditor | `python -m crypto.noise_lock --status`, `--release`; `python -m crypto.cacophony --check --write-status` | T73, T75, T78, T79 | self-generated vectors are not independent vectors |
| **APPROVED_CONTENT** | approved corpus + trust bundle | content editor / releasing authority | `python3 -m tools.readiness.run task T80 --stage narrow` | T78, T80 | the corpus is a rights-and-review decision, not a build step |
| **NATIVE_MODELS** | approved pinned native/model binaries | native build owner | `python3 -m tools.readiness.run task T81 --stage narrow` | T62–T65, T78, T81 | absent binary; `xcodebuild` needs `llama_cpp`, and `EncryptedStoreEngine` has no production conformer |
| **HARDWARE** | physical devices and BLE radios | device lab | `python3 -m tools.readiness.run task T74 --stage narrow` | T73–T76, T78 | `AndroidKeyStore not found` under Robolectric; a fake keystore would substitute the subject of the measurement |
| **SIGNING** | keys, keystore, store credentials | release owner | `python3 -m tools.readiness.run task T76 --stage narrow` | T76, T78 | secrets and store approval are external by definition |

## H. Board 2 starting point

Branch `board2/device-release-validation`, created from the green `main` HEAD after the merge.
Its SHA is recorded in `BOARD1_CLOSURE.json`.

Board 2 covers: physical Android/iPhone testing, real BLE interoperability, lifecycle and
process-death testing, locked-device/private-data tests, accessibility, battery/thermal,
long-running physical stress, approved A06 vectors, approved content, approved native/model
artifacts, signing, store submission, and the final independent production audit.
