# Status accounting — AUDIT-003-R1 (counts derived at round 88; narrative carried to round 97)

> **CURRENT STATE (2026-10-07) — DERIVED, NOT CARRIED.** *Everything below this banner is HISTORICAL
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
> C6 `21c23718` / `37382616410/1` passed all six prerequisites and fresh hosted mode-`all`.
> Actual downloaded portable proof passed the unchanged checker: eight cross-platform rows,
> two crash/recovery rows, two actual terminations and zero problems. Release `37382616464/1`
> captured internal PASS and external `BLOCKED_EXTERNAL`.
> Terminal `112064270922` was cancelled after 6h 1m 4s during the canonical loop; its 378 retained
> phase logs name 126 controls but supply no sealed manifest or 27-gate outputs. They are partial proof.
> Mirror write mode now preserves unchanged compiler-input bytes instead of deleting/recopying all
> generated Swift files, while pruning the same obsolete owned outputs and retaining strict checks.
> Semantic JVM phases force their selected Test with task-level `--rerun`, preserve prior-XML deletion
> and fresh named rosters, and no longer force unchanged compiler/KSP dependencies. No bound or oracle changed.
> Actual unpublished checkpoint `cd8187f5` passed the real Swift/Kotlin baseline/mutant/restored arms
> in 65.67s: intended defects killed, full restoration green, zero skips/invalid phases/timeouts.
> Generator CLI refused an obsolete source before write, removed it and passed strict checks after;
> unchanged compiler-input bytes/mtime survived two write/check cycles. DGX retains the proof at
> `mac-mini-offload/GODSTONE/evidence/board1-rc15-canonical-smoke-0b30do_i`.
> This selected repair smoke does not complete C6 or supply the next candidate's canonical population.
> The next immutable C must earn its own 179 semantic and two separately reported structural controls,
> fresh mode-`all`, all 27 local gates, seven hosted jobs and authenticated rc15/A replay; B remains untouched.
> `REMEDIATION_IN_PROGRESS`, five external obligations and zero `VERIFIED_FIXED` remain unchanged.
> C7 `66d061ec` / `37435793791` remained immutable through its approved whole-workflow retry.
> Attempt 1 ended in a GitHub internal iOS runner error. Exactly three conflicting original artifact
> ZIPs, 23,655,054 bytes, were SHA-verified on DGX before the user-approved deletion; no others deleted.
> Attempt 2 passed five non-iOS jobs and Foundation/UI steps, but real Simulator execution failed
> one of 1,406 tests: T15's 1.241s raw-advertisement flood saw zero refusals because its admission
> budget used real uptime instead of the transport's frozen injected clock. Raw exit was 65;
> terminal was skipped, and neither C7 attempt started mode-`all` or canonical controls.
> Actual release `37435793774/1` captured internal PASS and external `BLOCKED_EXTERNAL`.
> Unpublished repair checkpoint `58cfdc46` shares the existing resolved transport monotonic clock
> with both admission budgets; production default uptime, charge-before-parse, 65,536-record
> global limit, 1,000ms window and all registered controls remain unchanged. The existing T15 case
> now also proves next-window admission restoration. Actual Foundation baseline/restoration each
> passed 13 T15/T16 cases; a separate throwaway charge removal failed the named case with zero refusals.
> Actual registered iOS 26.3.1 Simulator passed all 13 selected cases, zero failures, 0.290s.
> Source digests agreed and restored checkpoint remained clean; native/stock bytes were verified
> in the built test bundle. DGX retains five complete logs, 53 hash-verified closed XCResult files
> and the actual receipt at `mac-mini-offload/GODSTONE/evidence/board1-rc15-scan-clock-smoke-ri1ro9kh`.
> Owned local scratch/device cleanup followed preservation; user devices and primary native stage remain.
> These are repaired-checkpoint smoke results, not a whole lane, final-C canonical population or freeze.
> Corrected immutable C must earn its own 179 semantic and two separately reported structural controls,
> fresh mode-`all`, ten lanes, all 27 local gates, seven hosted jobs and authenticated rc15/A replay.
> `REMEDIATION_IN_PROGRESS`, five external obligations and zero `VERIFIED_FIXED` remain unchanged.
> C8 `98269150` / `37481536356/1` passed all three real iOS lanes and fresh hosted mode-`all`;
> the iOS job finished in 3h 22m 26s. Actual downloaded mode-`all` passed the unchanged portable
> checker in 1.24s: eight cross-platform rows, two crash/recovery rows, two actual terminations,
> zero problems. Android failed in 1m 56s before tests during `:llm` configuration: absent NDK
> `27.0.12077973` downloaded as a non-ZIP. Terminal was skipped; no canonical campaign, ten-lane
> result, 27-gate proof, tag or freeze exists for C8. Release `37481536374/1` captured internal PASS
> and external `BLOCKED_EXTERNAL`. All 12 original repository ZIPs, 198,593,173 bytes, were
> parent SHA/size-verified at `mac-mini-offload/GODSTONE/evidence/rc15-final-98269150`; none deleted.
> The existing SDK installer now selects the measured Darwin/Linux pin by actual host, and the
> Ubuntu Android job explicitly provisions it before source sampling and consumer Gradle.
> Actual Linux cold install passed in 27.40s with SDK 12.0 and unchanged NDK `27.0.12077973`;
> actual Darwin default-root archive/tree verification passed in 0.46s. Exact SDK archive/tree
> identity, finite 64 licence inputs and consumer status remain; no fake-host proof is credited.
> The unchanged tree verifier's Path-component order is retained; the Linux pin uses its measured
> digest, not the precursor receipt's flat-relpath ordering. Mac pin identity remains unchanged.
> Actual receipts/logs are retained at
> `mac-mini-offload/GODSTONE/evidence/board1-rc15-linux-sdk-smoke-9h5b4ba3`.
> This pre-seal smoke neither supplies a final-C lane/campaign nor proves AMD64 compiler execution,
> NDK payload byte identity or future CDN health. Corrected immutable C still requires its own
> 179 semantic and two separately reported structural controls, fresh mode-`all`, ten lanes,
> all 27 local gates, seven hosted jobs and authenticated rc15/A replay; completed B is untouched.
> `REMEDIATION_IN_PROGRESS`, five external obligations and zero `VERIFIED_FIXED` remain unchanged.
> C9 `c56557ef` / `37517820872/1` completed FAILED at tree `ddeba2cfd5061909c8c53f668087dad057d9d77d`:
> constraints (38s), parity (703s), content (39s), meshsim (60s) and Android (587s, explicit Ubuntu SDK
> provision, all seven actual Android lanes) passed, Foundation passed 1533 actual tests / 98 suites / 0
> failures, and the iOS UI step ran 43 actual tests with ONE failure -- the real SOS-relaunch existence
> assertion at source line 450, 151.009s case. Terminal was SKIPPED; C9 has no Simulator, mode-`all`,
> canonical campaign, 27-gate or freeze result, is untagged, and is NOT final C. Its actual parent consumer
> of the downloaded ORIGINAL Android artifacts passed in 0.44s with zero skips/failures/errors (app 128,
> core 22, mesh 1479, labmesh 40, UI 168, Simulator 40, Production 1479): that is Android-only and neither
> judges iOS nor all ten lanes. All 11 original archive ZIPs, 23,706,754 bytes, were parent SHA/size-verified
> with zero mismatches and none deleted; the integration-evidence entry is FIXTURE-ONLY (29,506 bytes), not
> the actual mode-`all` population. Actual release `37517820947/1` captured internal PASS and external
> `BLOCKED_EXTERNAL` in 17.28s; its producer evidence is 301 files totalling 3,515,775 bytes, parent
> hash+size verified against the actual `producer-file-manifest.json`. A measured local relaunch diagnostic
> on the actual registered iOS 26.3.1 / `23D8133` Simulator (1 test / 0 failures, 16.817s, production source
> unchanged) captured the immediate post-relaunch hierarchy at t=12.18s showing five native tab-bar BUTTONS
> with declared labels and NO `lab.tab.*` identifier, while other actual controls kept their identifiers;
> the old SOS-identifier query first matched only at t=13.53s of that case. Native Text-identifier query
> fragility is thus measured locally; the exact hosted C9 cause is NOT, since no hosted hierarchy or
> XCResult was uploaded and the exact C9 case queried a Text identifier. The clean TEST-SIDE cutover to
> native button-label queries in both `app.tabBars.buttons[label]` and `app.buttons[label]` (same 45s bound,
> 150ms poll, no identifier/label mapping or fallback, unchanged censuses, production `lab.tab.*`
> declarations and the `ci/check_lab_isolation.py:484-488` guard untouched) is checkpointed immutably at
> parent C9 (`616402abee59dbcee859479a974e2c939c9e7cb0`, tree
> `342383cd02b5b4e8f9cead15021a0d6a51c203c1`). Its first two-scheme runner invocation failed BEFORE ANY ARM
> in 152.56s (exit 3) because a custom device name resolved against `OS:latest`, so zero schemes launched --
> a runtime-selection failure, not a source/UI regression, preserved and with no source or wait change; the
> parent then named the same owned iOS 26.3.1 device by explicit UUID
> `32ECCF0C-9EBA-4C67-8955-B3600009A01C` for the unchanged `LabMeshUI` + `GodstoneArchiveUI` complete actual
> smoke. That complete post-cutover local runtime has now actually PASSED: 43 actual case pass records
> with 2 `TEST SUCCEEDED` and the whole command in 730.74s -- LabMeshUI 29 actual tests / 0 failures /
> 0 skips / 0 expected failures (11 AX + 18 journey cases) and GodstoneArchiveUI 14 actual tests /
> 0 failures / 0 skips / 0 expected failures. The former C9 SOS-relaunch case actually passed in 16.202s
> on the owned 26.3.1 / `23D8133` iPhone 17 Pro arm64 device at SDK 27.0; no apples-to-apples speedup and
> no CI-27 equivalence is claimed. The exact clean source `616402ab…` / tree `342383cd…` start and end
> snapshots both reported `all[]` / ok, and the actual iOS pre/post digest was identical
> `1476060ae63bb635375eafda052e8238b2c8d2a302a888fcdd8dcffbf4d0da53`. The settled screenshot was read
> and observed as the normal Conversation UI with all five native tab buttons. The full closed console is
> 418,478 bytes, SHA-256
> `615068703c2b8cf0a0ca09c2f7c7153e72fea10b63c24b8f389c1e345dcc113c`; the two original XCResult archives
> are 6,100,812 bytes, SHA-256
> `cc1cb9a4e10d90e354bada508691d19f45f12bce462d77fbf3fac7b1ed8a0b82`, and the actual screenshots were
> retained, the first transition frame kept honestly beside the settled one. All SCP transfers and remote
> SHA-256 checks passed in the C9 DGX root, whose authoritative actual
> `actual-native-label-all-ui-smoke-receipt.json` is now complete. This is a SOURCE-CHECKPOINT
> post-fix smoke only: it is NOT final C, not a broadened C9 success and not a replacement hosted proof.
> The separate diagnostic
> XCResult+attachments archive is 393,418 bytes, SHA-256
> `fcb98c76b4347107b6b9e10e257793f9c4f7757761f7be13630644399bd87791`; its temporary instrumentation was
> removed before the checkpoint smoke. This is a source-query correction, not a production SOS/recovery
> change. Corrected immutable C still requires its own 179 semantic and two separately reported structural
> controls, fresh mode-`all`, all ten lanes, all 27 local gates, all seven hosted jobs and authenticated
> rc15/A replay; completed B and the completed canonical campaign are never rerun or relabelled.
> C10 `52f7a00b` (tree `c0ace1c5342c345125739c89e13097451bf16566`) / repository verification `37537225005/1`
> completed with all SIX prerequisites PASS -- constraints, parity and safety invariants (A,B,C,E,F,G,H),
> content, meshsim, the actual iOS job (10246s = 2h 50m 46s) and the Android job (all seven actual
> Android lanes, 884s) -- and its terminal job `112574909035` CANCELLED after 21648s (6h 0m 48s) mid-canonical
> campaign. The cancel yielded NO COMPLETED canonical campaign, NO gate manifest, NO 27-gate set, NO 179/2 score, NO tag
> and NO child A; C10 is untagged and is NOT final C, and no archive was deleted. The
> `board1-gate-manifest` upload was SKIPPED (its file never existed) while the separate post-cancel
> `always()` `board1-terminal-evidence` upload SUCCEEDED:
> artifact `11466006285`, 4,491,437 bytes, SHA-256
> `c94e987cbe8c7910383e6b1f8fab67223b723a9433687c4631e9e34c78628ef0`. The retained population is PARTIAL and
> manifest-less: 474 campaign phase logs (158 complete baseline/mutant/restored trios, written together after
> each serial row per `ci/mutations.py:3664-3670`) plus one release JSON -- 475 files -- and the per-outcome
> tally line never printed. The measured serial cause: the campaign ran rows serially, the three `ios-ui`
> controls each running the full 43-case UI lane three times; of 158 trio-write intervals exactly two exceed
> 600s, `IOS-WIPE-UX-002` 4958s (82m 38s) and `IOS-SOS-RETRY-001` 4878s (81m 18s), summing 9836s (2h 43m 56s),
> and those intervals INCLUDE the following rod's preparation, all three phases and the previous cleanup at the
> ZIP's 2s resolution -- NOT individual phase CPU. The last completed trio was `ARCHIVE-PROV-006` (06:44:18),
> leaving the next ordered `ios-ui` entry `ARCHIVE-PROV-007` in flight with its phase UNKNOWN [INFERENCE]. S2 is
> NOT failed: the 70 explicit baseline Swift build durations sum 4844.35s while the 69 mutant (431.51s)
> and 70 restored (405.86s) are already incremental; these are explicit build totals, not whole phase times.
> The actual original-data C10 all-ten-lane reader PASSED in 1.46s (Foundation 1533, UI 43, Simulator 1406,
> all seven Android lanes, zero skipped/failed/errored arms). The fresh mode-`all` producer
> `20261007T003625Z-b64458` PASSED strict consumption in 1.33s: 10 rows, eight cross-platform, two crash
> rows and two observed process deaths, zero problems. Source `52f7a00b` / `c0ace1c5…` stayed clean at both
> ends, with unchanged native compile input `93a68319…`; all 14 repository originals (219,020,797 bytes)
> were independently parent SHA/size-verified. This is C10-only evidence, never the next candidate's proof:
> `rc15-final-52f7a00b/actual-ten-lane-mode-all-original-consumer-receipt.json`.
> Release capture `37537225078/1` reported internal PASS and external `BLOCKED_EXTERNAL` in 16.78s but the
> release workflow was NOT all-green; its eight original artifacts, 15,278,928 bytes, were parent SHA/size
> verified with none deleted. The bounded TWO-resource-class executor's actual pre-seal smoke PASSED at
> `3c1e9e4cf83b8c98d5a6af2734b95ba8d7da4c13` / tree `5ef03db5f0c8b89bfe16fe515bae85045ac10bb0` in 2360.28s:
> **two semantic smoke controls KILLED** (JVM and Swift, 15 cases per phase); **one structural smoke control KILLED**
> (`ARCHIVE-PROV-007`, the full 43-case UI lane in all three phases), reported SEPARATELY. Baseline/restored green,
> named mutant witnesses observed, equal phase rosters, zero skips/invalid/incomplete/timeout/escape; the ten original
> files (2,018,020 bytes) were independently remote SHA/size-verified and all nine log digests matched the manifest.
> Non-UI rod-work bounds remained serial and overlapped UI rod work by 36s and 47s, including preparation/native/build
> and tests — NOT per-phase or simultaneous-test timing. Source SHA/tree and clean `all=[]` matched at both ends.
> Receipt: `rc15-final-52f7a00b/actual-bounded-two-class-executor-real-smoke-receipt.json`. No stub or old campaign used.
> This subset is NOT the final 179-semantic/2-structural score. No final C11 SHA is claimed; fresh mode-`all`, all ten
> lanes, all 27 local gates, all seven hosted jobs, separate 179 semantic + 2 structural controls and rc15/A replay
> remain required and unchanged. Five external obligations OPEN/BLOCKED and zero
> `VERIFIED_FIXED` remain unchanged.

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
