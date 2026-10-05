# Status accounting — AUDIT-003-R1 (counts derived at round 88; narrative carried to round 97)

> **CURRENT STATE (2026-10-05) — DERIVED, NOT CARRIED.** *Everything below this banner is HISTORICAL
> audit-trail narrative from the round-88/97 era and is preserved verbatim; it must NOT be read as the
> current state.* **The current canonical state is DERIVED from the structured obligations by
> `scripts/build_structured_closure.py`: 35 internal obligations DISCHARGED and 0 OPEN -- NO finding remains internally
> OPEN (the four `AUDIT-B1-CTRL-001` closure-control discharges are now earned by their OWN scope-specific
> generator-semantic strike evidence at preparatory B `46903cd0` over unchanged guard logic, not fake-closed;
> the C0 negative-input court remains distinct history). The restoration-disconnection mutation
> `gs-final-006.mutation` is DISCHARGED on its OWN separate four-rod restoration campaign
> (baseline `46903cd040ffae9f2cd20529aad54ac6166bd6ad`, tested tree `d74dc5e2679b69358663402e8c4711bea0d519db`),
> all four SEMANTIC controls KILLED with restored-green, NEVER aggregated with the canonical controls.
> Every discharged obligation carries an authored, production-reachable
> `structured_discharge` (seven fields + external `candidate_binding` naming only the prospective rc15 ref, the external
> evidence bundle manifest `docs/remediation/evidence/board1-evidence-bundle.json` and the future attestation path
> `FREEZE_ATTESTATION_rc15.json` reserved until freeze -- no closure SHA embedded); the per-obligation source-review history is carried
> in place as `review_gap_history`, and a terminal obligation may carry that history ONLY when every attached defect is
> `REPAIRED_STALE`,
> 5 external obligations; `findings_with_internal_status_open = 0`; `internal_obligations_open = 0`; `verified_fixed = 0`; builder
> status `REMEDIATION_IN_PROGRESS`; prospective candidate `production-readiness-board1-rc15`.**
> **Source census (2026-10-04):** all 42 authored review-defect verdicts are `REPAIRED_STALE` / 0 `PARTIAL` /
> 0 `LIVE`; the iOS UI role roster passed 43 tests / 0 failures in all four combinations. Human
> VoiceOver/TalkBack acceptance remains the existing external obligation.
> **Preparatory campaign (2026-10-05):** baseline `46903cd040ffae9f2cd20529aad54ac6166bd6ad`,
> tested tree `d74dc5e2679b69358663402e8c4711bea0d519db`: **179 SEMANTIC controls KILLED and
> 2 STRUCTURAL controls KILLED, reported separately**, every required control restored-green.
> Source-aware manifest validation passed; the raw manifest and 543 digest-checked phase logs are
> clone-carried at `docs/remediation/evidence/board1-rc15-candidate-46903cd0/canonical-campaign/`.
> All ten B lanes and the separate four restoration controls and five generator strikes remain separately scoped.
> **Supply preflight (2026-10-04):** the four supply refusals were repaired by the canonical generators only:
> `ios/project.yml` fingerprint `0c4a39…`, SBOM 566 components including 3 SQLite 2.6.2 coordinates, and six
> CycloneDX faces refreshed. `verify --all` and `sbom-export --check` passed with honest warnings:
> cmake absent, unpinned tool versions and debug-dex nondeterminism; reproducibility is not claimed.
> **Final immutable C still requires its own strict campaign, integration and candidate-bound gate proof,
> authenticated hosted green, annotated rc15 tag and attestation-only successor.** The five external obligations
> and independent verification remain outstanding: no finding carries `closure_evidence`, no finding is
> `VERIFIED_FIXED`, and no READY/COMPLETE claim is made. Historical `PARTIAL`/`OPEN` narrative below is superseded.
> Hosted probe `a73da925` / `37266700328` attempt 1 failed only iOS stock-oracle supply; its selected
> iOS 27.0 runtime lacked the plain Apple SQLite image, and the terminal campaign was skipped.
> The corrected workflow explicitly provisions the registered iOS 26.3.1 / `23D8133` arm64 runtime.
> Local create/reuse and actual stock-image staging passed without downloading a runtime; no native
> validation guard changed. Hosted probe `3883c9f3` / `37275912694` attempt 1 then passed all six prerequisites,
> including the actual registered runtime, identical stock-image digest and all 1406 simulator tests.
> Its terminal job failed release capture before any canonical campaign or gate manifest: log-retrieval errors
> were discarded into an empty log. The underlying hosted retrieval cause was not retained; `UNKNOWN STEP`
> display labels do not break the existing raw-command parser.
> The corrected exact-run/attempt/job archive reader captured actual release `37275912618/1` successfully
> in 15.43s with internal PASS and external `BLOCKED_EXTERNAL`, without weakening any boundary or identity guard.
> The hosted integration producer completed eight cross-platform and two crash rows, but downloaded replay
> refused host-specific compiled/image paths; that producer result did not carry portable tested bytes.
> Both probes remain untagged. A new immutable candidate still requires its own campaign, portable integration,
> all 27 gates, all seven hosted jobs and authenticated freeze; no completed preparatory proof is relabelled.
> Fresh build attestations now require schema 3 and digest-bound `tested-bytes.tar` beside the report;
> the tested bundle and verified native image/descriptor travel with the artifact, without runner-path fallback.
> Actual compiled/native bytes were archived on DGX and accepted by the served-byte reader (30935040 bytes).
> All 15 integration behavior tests and 43 isolated gate selftest cases passed; these do not count as canonical
> controls or fresh mode-`all` candidate proof. The next immutable run must produce that report itself.
> Post-worker publication revalidates the live build against the retained archive. A real compiled-bundle
> copy changed after retention was refused; the original input was untouched and the temporary copy removed.
> Hosted probe `5118d94e` / `37310847380` attempt 1 then failed Android: one of 1479 tests closed
> the half-spoken handshake while the fixture claimed an exact duplicate. The fixture had replayed only
> the first fragment of HS1, not its complete 32-byte payload; MTU/startup ordering exposed the truncation.
> T23 now uses the existing T22 full-record reassembly pattern for both HS1 and HS2 duplicate fixtures.
> The real affected class passed **18 tests / 0 failures / 0 errors / 0 skips**; duplicate acceptance,
> fresh-sequence refusal and heard-once assertions are unchanged, and no production authority changed.
> iOS remained in progress at that checkpoint; no C3 canonical campaign started and no rc15 tag exists.
> A newly committed candidate must earn its own remaining exact-C proofs; the failed probe is not relabelled.
> C3's completed iOS aggregate also failed: 1406 Simulator tests reported two assertions in the same
> seeded failure-address arm. The deliberately injected slot, seed/cycle/class and resource census
> matched across both replays; only wall-clock `sweepTicks=10` versus `0` differed.
> The private failure address excludes that heartbeat; the actual leak oracle and separate liveness
> witness remain. The obsolete repeated delimiter comparison was deleted rather than repinned.
> Hosted C4 `a71c697c` / `37324195279/1` passed its five non-iOS prerequisites, including repaired
> Android, but failed the LabMesh octet-readout predicate wait before Simulator/integration/terminal
> proof. Its announcement arm now uses the existing live-tree polling convention, unchanged bounds,
> real readout/outcome/door assertions and the actual pre-send outcome baseline instead of English wording.
> Actual release `37324195277/1` captured internal PASS and external `BLOCKED_EXTERNAL`.
> Pre-seal smoke passed both real seeded-runtime/liveness arms on Foundation and registered iOS
> 26.3.1 Simulator (two tests, zero failures per surface), and the actual multibyte-input → outcome →
> announcement UI arm on iOS 26.5 (one test, zero failures). DGX retains logs and source/native receipts
> at `mac-mini-offload/GODSTONE/evidence/board1-rc15-ios-fixture-smoke-xj8m3hnk`.
> These selected-path results do not relabel failed C3/C4, supply a canonical campaign or satisfy fresh
> mode-`all`. Corrected immutable C must still earn 179 semantic and two separately reported structural
> controls, all 27 local gates, all seven hosted jobs and authenticated rc15 freeze.
> Completed C5 `9aaf7fc0` / `37346047303/1` passed all three real iOS lanes, but failed later in
> mode-`all` integration: the first honest Android worker never emitted startup identity within 600s,
> and its retained log ended in KSP compilation. Android's separate lane failed installing a non-ZIP
> NDK `27.0.12077973` payload; no fresh Android test verdict is claimed.
> The coordinator no longer forces the entire warmed compiler graph to rerun for every worker.
> Its dedicated Gradle Test still always executes freshly; task/class, source/native evidence,
> process termination and the 600s bound are unchanged. The full Android lane remains forced.
> Actual unpublished repair checkpoint `9845229e` passed complete mode-`all` in 173.14s: eight
> cross-platform rows, two crash/recovery rows, two authenticated crash terminations and zero
> evidence-checker problems. Source digests agreed; DGX retains 134 hash-verified regular proof
> files at `mac-mini-offload/GODSTONE/evidence/board1-rc15-worker-smoke-pz_k5q_0`.
> Actual C5 release `37346047147/2` captured internal PASS and external `BLOCKED_EXTERNAL`.
> These are pre-seal repair results, not a final-C campaign or freeze. C5 remains failed, untagged
> and campaign-free. Final immutable C must still earn its own separately reported 179 semantic
> and two structural controls, fresh mode-`all`, 27 local gates, seven hosted jobs and rc15/A replay.
> `REMEDIATION_IN_PROGRESS` and the five open/blocked external obligations remain unchanged.

The COUNTS and the class memberships are re-derived from `REMEDIATION_STATE.json`; the narrative
sections are maintained by hand and say so. Nothing here is new evidence. It states the
classes the remediation requires, in the audit's own terms, and it is regenerated rather than
hand-edited so that a status cannot be quietly carried forward.

**Ledger at this refresh: 27 `FIX_SUBMITTED`, 2 `PARTIAL`, 0 `RED_WRITTEN`, 25 `OPEN` — and ZERO `VERIFIED_FIXED`.** Only an independent audit may write `VERIFIED_FIXED`, and the ledger court refuseth the word from this work. NO finding carries any `closure_evidence`.

AT ROUND 97 the AUDIT-004 limb of `GS-CTRL-001` landed (`bf839fa`) and changed NO status: it is a
deeper limb of an already-submitted finding, so 27 `FIX_SUBMITTED` and 2 `PARTIAL` stand unchanged.
What it changed is MEASURABLE: the independent review's own 10-case probe suite
(`AUDIT_FINAL_2026-09-15/evidence/AUDIT-004/independent_repair_probes_v2.py`), which reported
**8 failures / 2 passes** at ae9905e and at the audit's own pin 33be0b0b, now reporteth
**5 failures / 5 passes** at `bf839fa` — its three GS-CTRL-001 probes pass, and the five that
remain (two for `GS-GATE-001`, one each for `GS-CONTENT-001`, `GS-CONTENT-002` and the
`GS-CONTENT-003` regression) are the next rounds' work, each already a reproduced failing assertion.

The same limb exposed, by making the law stricter rather than looser, that **T05's mutation record
was never evidence**: it carrieth no log, no failure roster, no source identity and no
restored-green companion, so the mutation control it asserted is **NOT ESTABLISHED**. It is now
recorded as an explicit evidence gap (never an exemption, and nothing deleted), and `validate-state`
stayeth green with one new, named note.

`GS-CTRL-002`'s AUDIT-004 limb also landed at round 97 (`7c04539`): the content lane declared the
rehearsal's external report path but NEVER uploaded it, so the rehearsal left no retrievable
artifact. The canonical court now DERIVES the expected upload path from the lane's own env and the
rehearsal's own `--report` argument and requires `if: always()`. Every mandatory lane stayeth
mandatory (the gate checker still refuseth an amputated lane by name).

AT ROUND 98 two more AUDIT-004 limbs landed and changed NO status either (`1dcfbc1` for
`GS-GATE-001`, `8e9a8e9` for `GS-CONTENT-003`): both are deeper limbs of already-submitted findings.
What they changed is MEASURABLE, and it is the auditor's own suite that says so: **8 of its 10 cases
now PASS** (it was 2 of 10 at the audit's own pin and at ae9905e). Six of the eight reproduced
failures are repaired, one per round. The two that remain are `GS-CONTENT-001`'s forged-digest
staging and `GS-CONTENT-002`'s process-death mixed pair.

AT ROUND 100 (`1a31f47`) THE AUDITOR'S OWN TEN-CASE SUITE WENT FULLY GREEN: **10 pass, 0 fail**,
where the audit's pin was 8 failures and 2 passes. All eight reproduced failures are repaired, one
finding-limb per round, across rounds 97-100 (GS-CTRL-001's three evidence bypasses, GS-GATE-001's
two gate bypasses, GS-CONTENT-003's regression, GS-CONTENT-001's zero-coverage staging, and
GS-CONTENT-002's process-death mixed pair). THIS IS NOT A CLOSURE: the suite was written before the
repairs, only an independent audit may write `VERIFIED_FIXED`, and the depth each finding still owes
is stated per finding in the ledger.

AT ROUND 99 (`b5d6a4b`) the canonical CONTENT suite's long red is CLOSED: it was 69 cases with 14
assertion failures and 10 errors at the audit, 71/13/10 after round 98, and **75 cases, OK** now. The
repair was two-sided and neither side was a relaxation: the staging face refuseth a ZERO, an ABSENT
and a NON-NUMERIC coverage claim for the final chunk approvals, and the FIXTURES were repaired to
exercise the newly mandatory provenance instead of production validation being loosened to keep them
green. THE AUDITOR'S OWN SUITE NOW REPORTS 1 FAILURE / 9 PASSES (it was 8/2 at the audit's pin):
only `GS-CONTENT-002`'s process-death mixed pair remaineth.

An earlier text of this section, kept for the record, said: the canonical CONTENT suite is STILL RED -- 71 cases, 13 assertion failures, 10 errors (it was
69/14/10 before round 98, so nothing was made worse) -- and its root cause is now NAMED rather than
guessed: the class fixtures omit the provenance metadata GS-CONTENT-001 made mandatory, so old
POSITIVE cases fail too early. That is the CONVERGENCE failure AUDIT-004 recorded, not 23 new
product defects, and it is the next round's highest-value work: repair the FIXTURES to exercise the
new contract, never relax production validation to make them green.

A ledger-wide evidence recheck at round 97 resolved **157** log and red-case references on disk and
found **0 defects** -- round 96 had left one instance (a path under the wrong key with a NULL
digest), which was corrected by MEASURING the file, not by asserting it.

AT ROUND 88 the four landings of this session (GS-SOS-002 step 6, GS-ACK-001 step 4, GS-SYNC-002
step 3 on BOTH isles, plus the android lane-flake fix) changed NO status: 27 `FIX_SUBMITTED` and
2 `PARTIAL` stand, no gate moved, and `GS-SYNC-002` is the first finding with a captured red on
BOTH isles for the same law.

## 1. Submitted and awaiting INDEPENDENT verification — 29

| Finding | Status | Wave | Fix commit (first limb) |
|---|---|---|---|
| `ANDROID-02` | FIX_SUBMITTED | 4d.2 | 098fcb2 |
| `CRYPTO-003` | FIX_SUBMITTED | 4b | 565c14a |
| `CRYPTO-004` | FIX_SUBMITTED | 4b | 5c03d069506de0dded390071ec9937d8395a94bc |
| `CRYPTO-006` | FIX_SUBMITTED | 4b | 92104a7 |
| `GS-ACK-001` | FIX_SUBMITTED | 5 | 6f7d08c |
| `GS-ACK-002` | FIX_SUBMITTED | 5 | bae4eba |
| `GS-ARCHIVE-001` | FIX_SUBMITTED | 2 | 719772b |
| `GS-ARCHIVE-002` | FIX_SUBMITTED | 2 | 094cf3f |
| `GS-ARCHIVE-003` | FIX_SUBMITTED | 2 | 28f5e5a |
| `GS-ARCHIVE-004` | FIX_SUBMITTED | 2 | ba0dd69 |
| `GS-ARCHIVE-005` | PARTIAL | 2 | 4857a72 |
| `GS-CONTENT-001` | FIX_SUBMITTED | 2 | d4dbd3a |
| `GS-CONTENT-002` | FIX_SUBMITTED | 2 | bd28128 |
| `GS-CONTENT-003` | FIX_SUBMITTED | 2 | dbbc0b4 |
| `GS-CTRL-001` | FIX_SUBMITTED | 1 | 9d39c36d1804aee294b2227d584686453418fd7b |
| `GS-CTRL-002` | FIX_SUBMITTED | 1 | 50fc81b |
| `GS-DIAG-001` | FIX_SUBMITTED | 8 | PENDING |
| `GS-GATE-001` | FIX_SUBMITTED | 1 | e0e0fae |
| `GS-MODEL-001` | FIX_SUBMITTED | 3b | PENDING |
| `GS-PACKAGE-001` | FIX_SUBMITTED | 3a | PENDING |
| `GS-PACKAGE-002` | FIX_SUBMITTED | 3a | PENDING |
| `GS-SOS-002` | FIX_SUBMITTED | 5 | fc13b30 |
| `GS-STORE-001` | FIX_SUBMITTED | 4a | PENDING |
| `GS-STORE-002` | PARTIAL | 4a | PENDING |
| `GS-STORE-003` | FIX_SUBMITTED | 4a | 98c69c58f8420bdf6c5345278d1804f6ca1596dc |
| `GS-SUPPLY-001` | FIX_SUBMITTED | 3a | PENDING-COMMIT |
| `GS-SYNC-001` | FIX_SUBMITTED | 5 | 5b1ace9 |
| `GS-SYNC-002` | FIX_SUBMITTED | 5 | bbe4ffb |
| `IOS-03` | FIX_SUBMITTED | 4d.1 | 19a4635 |

## 2. A captured red — 29 findings

Every finding moved off `OPEN` carries `my_red_case` with argv, log path, sha256 and outcome; the ledger
court refuseth a submission without one. The count is a floor, not a claim: a red proveth the failure
EXISTED, and only an independent audit can call a repair closed.

## 3. Dependent on EXTERNAL artifacts or on a device/hosted lane — 27

Classified mechanically by a STATED rule: a submitted finding is listed when any of its `pending_proof`
entries names a device, an external artifact, SQLCipher, the hosted lane, or a radio — so the
classification can be re-derived rather than trusted. The five external requests (`A06`, `T79`, `T80`,
`T81`, `T76`, plus the `T73`–`T75` hardware lane) live in `EXTERNAL_INPUT_REQUESTS.md`: exact requests,
named owners, immutable acceptance requirements. **ACQUISITION CLOSES NOTHING**, no gate has moved for
any artifact, and every blocker still carries `closure_evidence` = NONE.

| Finding | What it awaits (first matching sentence) |
|---|---|
| `ANDROID-02` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. No real advertisement was scanned and no radio delivered HS2; the whole exchange runs through t |
| `CRYPTO-003` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. Post-destroy PLAINTEXT LEAKAGE and KEY RECOVERY are NOT claimed: the audit itself records that  |
| `CRYPTO-004` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. A hostile sealed frame arriving over a real radio path is not exercised; every result here is a |
| `CRYPTO-006` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED, and the race is a FIXTURE INTERLEAVING on the host (the loser's first read misses), not observe |
| `GS-ACK-001` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: the arms drive the real inbox commit and the real restart worker on the host; no peer and no ra |
| `GS-ACK-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. The TTL-12 return path's reach was NOT exercised over the air or across multiple hops; the repa |
| `GS-ARCHIVE-001` | no emulator or device was used: the harness is the real bundled driver on the HOST |
| `GS-ARCHIVE-002` | no emulator or device was used: the harness is the real bundled driver on the HOST, which is the same engine the shipping APK installeth, bu |
| `GS-ARCHIVE-003` | the card's Dynamic Type / TalkBack pass and the Android system-Back binding are NOT done; no emulator or device was used |
| `GS-ARCHIVE-004` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-ARCHIVE-005` | no simulator or device run: the scene courts are HOST tests, and the card's closure requireth an interaction test |
| `GS-CONTENT-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-002` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CONTENT-003` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-CTRL-002` | the hosted lane: no hosted run URL/log was available to this work, so every result here is a LOCAL reproduction of the constituent commands; |
| `GS-DIAG-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-GATE-001` | the hosted lane: no hosted run URL/log was available, so the hosted convergence the R1 supplement requireth remains pending |
| `GS-MODEL-001` | NO native inference, no model download and no device were used: the arms build synthetic files and a fixture artifact, and the pinned models |
| `GS-PACKAGE-001` | no signed IPA, no real entitlement blob and no device were used: the arms mock ONLY the codesign OS boundary, and the inspector policy is re |
| `GS-PACKAGE-002` | no real AAB or release artifact was inspected: the arms build SYNTHETIC containers confined to a TemporaryDirectory, and no device or bundle |
| `GS-SOS-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: the red and every green are HOST courts driving each node's own command door with a synthetic callback that c |
| `GS-STORE-001` | no native cipher, no encrypted device store and no real SQLCipher file: the proofs are over REAL FILES' BYTES and the native seam remains a  |
| `GS-STORE-003` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED. The Android PRODUCTION road (SQLiteOpenHelper.onUpgrade + DatabaseMigrationExecutor over SQLite |
| `GS-SUPPLY-001` | no hosted run URL/log was available, so hosted convergence remains pending |
| `GS-SYNC-001` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: both arms drive the owner's real control-frame entry on the host with canonical frames; no peer |
| `GS-SYNC-002` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED: the differential is a host court driving each node's own entries with canonical control frames; |
| `IOS-03` | NO DEVICE/EMULATOR/SIMULATOR/RADIO WAS USED on either isle: no real advertisement was scanned and no radio delivered HS2. |

## 4. Closure evidence STALE because a production owner changed — 29 findings

The audit's per-finding review records source identity at the audited SHA. For every finding this work has
TOUCHED, a production owner HAS changed: the anchor files no longer match HEAD, so that review is STALE BY
CONSTRUCTION and nothing in it may be quoted as closure. This is the audit's own doctrine — source
identity never proved the whole caller graph unchanged.

Touched, and therefore stale: `ANDROID-02`, `CRYPTO-003`, `CRYPTO-004`, `CRYPTO-006`, `GS-ACK-001`, `GS-ACK-002`, `GS-ARCHIVE-001`, `GS-ARCHIVE-002`, `GS-ARCHIVE-003`, `GS-ARCHIVE-004`, `GS-ARCHIVE-005`, `GS-CONTENT-001`, `GS-CONTENT-002`, `GS-CONTENT-003`, `GS-CTRL-001`, `GS-CTRL-002`, `GS-DIAG-001`, `GS-GATE-001`, `GS-MODEL-001`, `GS-PACKAGE-001`, `GS-PACKAGE-002`, `GS-SOS-002`, `GS-STORE-001`, `GS-STORE-002`, `GS-STORE-003`, `GS-SUPPLY-001`, `GS-SYNC-001`, `GS-SYNC-002`, `IOS-03`.

## 5. What is proven nowhere in this work

- No device, emulator, simulator or radio was used anywhere: every result is a LOCAL host reproduction,
  and no fixture or simulated counter is ever relabelled as a device or runtime result.
- No hosted lane exists in this environment: there is no CI run URL, run id or hosted log for any of it.
- T78 final convergence is NOT run: it needs ONE clean exact candidate SHA with fresh green canonical AND
  hosted controls, and the hosted controls do not exist here.
- Readiness flags stay FALSE and both declared candidates stay `NO_GO` (LIGHT Archive and Mesh/Oracle).
- The in-flight dispatch boundary is NOT expressed anywhere: nothing in the current result taxonomy
  distinguishes "an offer is crossing the writer right now, its outcome unknown" from "no offer ever
  crossed", because `SosCancelResult.wasRelayed` means "bytes had ALREADY gone out" and a pre-existing
  mandatory court pins a mid-flight cancellation to `false`. `GS-SOS-002`'s ordered step 3 (serialize cancel
  with offer admission) therefore remains OPEN, and round 85 withdrew both an unred-gated serialization and
  an arm that would have overloaded that boolean rather than leave either claim in the tree unproven.

## 6. The green-lane claim, and the flake that used to weaken it

The android lane's intermittent FIXTURE flake ('no ascending hint pair within 64 draws') is ROOT-CAUSED and
FIXED at round 86. The earlier reading — 65 non-ascending draws being "statistically impossible", therefore
shared RNG state — was WRONG: the fixture in `ReadinessT17Test`/`ReadinessT18Test` redrew `b` ALONE against a
FIXED `a`, so acceptance probability per draw was `(255 - a.hint[0])/256`, not one half; with `a.hint[0] = 254`
it needed the 1/256 case 65 times and failed ~78% of the time. Measured: `a=(254,25,59,239)`, and NINE of
THIRTY filtered runs failing in fixture setup. The two courts now ORDER the drawn pair instead of fishing on
that coin, verified by the same thirty-iteration protocol; the other five courts carry the both-redrawn shape,
whose acceptance probability is ~1/2 and whose 65-draw failure is genuinely impossible.

The limitation this section used to state is therefore retired for THIS flake — 'the lane is green' now means
the logged passing run AND a fixture that cannot fail on a 1/256 coin — while the older caveat still stands
for anything not re-measured: every claim in this document is a LOCAL host reproduction.
