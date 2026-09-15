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

## Kotlin probe — `kotlin/t26-full-node-id-witness.kt.txt` (ANDROID-07 / T26 step 2's full-NodeID half)

Parked, **not** red-by-design: this witness was RUN (through `ReadinessT17Test`'s real trusted handshake) and it
**failed on a measurement rather than on an absence** — `SessionManager.authenticatedNodeIdOf(peerId)` answers
**null before AND after trust**, so the crypto layer does not surface the authenticated remote static key through the
SessionManager at READY. The production edits it judged were therefore **reverted** (no red lane, no unverifiable
claim), and the witness is kept here with its measurement and its named next step so the next attempt begins from a
witness rather than a search. **When the crypto-layer step lands, this witness moves INTO `ReadinessT17Test`** — the
court whose rig owns the real handshake — and this section is deleted.
